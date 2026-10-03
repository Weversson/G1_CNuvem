#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

for dependency in docker python3; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'Comando necessário não encontrado: %s\n' "$dependency" >&2
        exit 1
    fi
done

if ! docker compose version >/dev/null 2>&1; then
    printf 'Instale o plugin Docker Compose antes de executar o teste.\n' >&2
    exit 1
fi

show_failure() {
    printf '\nTeste interrompido. Últimos logs dos serviços:\n' >&2
    docker compose logs --tail=30 >&2 || true
}
trap show_failure ERR

docker compose up -d --build --wait --wait-timeout 120

python3 - <<'PY'
import concurrent.futures
import json
import subprocess
import time
import urllib.error
import urllib.request
from uuid import uuid4


SERVICES = {"app1": 5001, "app2": 5002, "app3": 5003}
RUN_ID = str(uuid4())
EXPECTED = {name: [] for name in SERVICES}
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def compose(*arguments, **kwargs):
    return subprocess.run(["docker", "compose", *arguments], check=True, text=True, **kwargs)


def request(name, path, payload=None, headers=None, raw=None):
    data = raw if raw is not None else (
        json.dumps(payload).encode("utf-8") if payload is not None else None
    )
    request_headers = {"Content-Type": "application/json"} if data is not None else {}
    request_headers.update(headers or {})
    req = urllib.request.Request(
        f"http://127.0.0.1:{SERVICES[name]}{path}",
        data=data,
        headers=request_headers,
    )
    try:
        response = HTTP.open(req, timeout=15)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, json.load(response)


def messages(name):
    status, body = request(name, "/messages")
    require(status == 200 and isinstance(body, list), f"Consulta inválida em {name}: {body}")
    return body


def send(name, text):
    status, body = request(name, "/send", {"message": text})
    require(status == 201, f"Envio por {name} falhou: HTTP {status}, {body}")
    peers = {peer: "ok" for peer in SERVICES if peer != name}
    require(body.get("replication") == peers, f"Replicação incompleta: {body}")
    record = body["message"]
    require(record["origin"] == name and record["message"] == text, "Conteúdo alterado no envio.")
    return record


def verify_records():
    for name, expected in EXPECTED.items():
        saved = messages(name)
        for record in expected:
            matches = [item for item in saved if item["id"] == record["id"]]
            require(matches == [record], f"Mensagem ausente, duplicada ou alterada em {name}: {record['id']}")


def verify_files():
    # A leitura ocorre em app1, que deve enxergar os três logs pelo volume.
    code = '''
import json
import pathlib
import sys
expected = json.load(sys.stdin)
for name, records in expected.items():
    path = pathlib.Path("/data") / (name + ".log")
    saved = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
    for record in records:
        matches = [item for item in saved if item["id"] == record["id"]]
        if matches != [record]:
            raise SystemExit("Log inconsistente: " + str(path))
print("OK: os três arquivos de log estão no volume compartilhado.")
'''
    compose("exec", "-T", "app1", "python", "-c", code, input=json.dumps(EXPECTED))


print("1/7: envio pelas três instâncias e conferência de todas as cópias.", flush=True)
for name in SERVICES:
    record = send(name, f"Teste {RUN_ID}: olá, {name}!\nSegunda linha com acentuação.")
    for expected in EXPECTED.values():
        expected.append(record)
verify_records()

print("2/7: rejeição de dados inválidos.", flush=True)
before = {name: messages(name) for name in SERVICES}
for name in SERVICES:
    for payload in ({}, [], {"message": None}, {"message": 42}, {"message": "   "}, {"message": "x" * 4097}):
        status, _ = request(name, "/send", payload)
        require(status == 400, f"JSON inválido foi aceito por {name}: {payload!r}")
    status, _ = request(name, "/send", raw=b'{"message":')
    require(status == 400, "JSON incompleto deveria retornar HTTP 400.")
    status, _ = request(name, "/send", raw=b"texto", headers={"Content-Type": "text/plain"})
    require(status == 415, "Tipo de conteúdo incorreto deveria retornar HTTP 415.")
    status, _ = request(name, "/send", {"message": "sem metadados"}, headers={"X-Replication": "true"})
    require(status == 400, "Cópia sem metadados deveria retornar HTTP 400.")
    status, _ = request(name, "/send", {"message": "x" * 70000})
    require(status == 413, "Corpo muito grande deveria retornar HTTP 413.")
require(before == {name: messages(name) for name in SERVICES}, "Uma entrada inválida foi gravada.")

print("3/7: controle de duplicatas e de conflitos de identificador.", flush=True)
record = EXPECTED["app1"][0]
status, body = request("app2", "/send", record, headers={"X-Replication": "true"})
require(status == 200 and body.get("duplicate") is True, "A cópia repetida não foi reconhecida.")
status, _ = request("app2", "/send", {**record, "message": "conteúdo diferente"}, headers={"X-Replication": "true"})
require(status == 409, "Um ID existente não pode receber outro conteúdo.")
time.sleep(1)
require(before == {name: messages(name) for name in SERVICES}, "A repetição gerou gravações adicionais.")

print("4/7: seis envios simultâneos.", flush=True)
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    futures = [
        pool.submit(send, f"app{index % 3 + 1}", f"Teste {RUN_ID}: envio simultâneo {index}")
        for index in range(6)
    ]
    for future in futures:
        record = future.result()
        for expected in EXPECTED.values():
            expected.append(record)
verify_records()

print("5/7: arquivos independentes no mesmo volume.", flush=True)
verify_files()

print("6/7: falha de um destino sem perda da mensagem na origem.", flush=True)
try:
    compose("stop", "app3")
    status, body = request("app1", "/send", {"message": f"Teste {RUN_ID}: app3 indisponível"})
    require(status == 202, f"A falha parcial deveria retornar HTTP 202: {body}")
    require(body["replication"] == {"app2": "ok", "app3": "erro"}, "A resposta não identificou o destino indisponível.")
    partial = body["message"]
    EXPECTED["app1"].append(partial)
    EXPECTED["app2"].append(partial)
finally:
    compose("up", "-d", "--wait", "--wait-timeout", "120")
verify_records()
require(not any(item["id"] == partial["id"] for item in messages("app3")), "app3 leu a mensagem sem recebê-la por HTTP.")

print("7/7: remoção e recriação dos containers, preservando o volume.", flush=True)
snapshot = {name: messages(name) for name in SERVICES}
try:
    compose("down")
finally:
    compose("up", "-d", "--wait", "--wait-timeout", "120")
require(snapshot == {name: messages(name) for name in SERVICES}, "Os dados mudaram após recriar os containers.")
verify_files()
print("Todos os testes passaram. Os três serviços continuam em execução.", flush=True)
PY
