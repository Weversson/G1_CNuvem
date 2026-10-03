"""Serviço de mensagens com replicação HTTP e armazenamento em JSON Lines."""

import fcntl
import json
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse
from uuid import UUID, uuid4

import requests
from flask import Flask, jsonify, request


app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024
app.json.ensure_ascii = False
app.logger.setLevel(logging.INFO)

APP_NAME = os.getenv("APP_NAME", "app1")
if APP_NAME not in {"app1", "app2", "app3"}:
    raise ValueError("APP_NAME deve ser app1, app2 ou app3.")

PEERS = [url.strip().rstrip("/") for url in os.getenv("PEERS", "").split(",") if url.strip()]
DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
DATA_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = DATA_DIR / f"{APP_NAME}.log"
LOG_FILE.touch(exist_ok=True)


class MessageConflict(Exception):
    """O identificador já pertence a outra mensagem."""


def read_messages():
    with LOG_FILE.open("r", encoding="utf-8") as file:
        # O bloqueio impede a leitura de uma linha ainda em gravação.
        fcntl.flock(file, fcntl.LOCK_SH)
        return [json.loads(line) for line in file]


def store_message(message):
    """Grava uma única vez por ID, mesmo com requisições simultâneas."""
    with LOG_FILE.open("a+", encoding="utf-8") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        file.seek(0)
        for line in file:
            saved = json.loads(line)
            if saved["id"] == message["id"]:
                if saved != message:
                    raise MessageConflict
                return False

        file.write(json.dumps(message, ensure_ascii=False) + "\n")
        file.flush()
        os.fsync(file.fileno())
        return True


def validate_replica(payload):
    """Valida os metadados que acompanham uma cópia entre containers."""
    try:
        identifier = str(UUID(payload["id"]))
        created_at = datetime.fromisoformat(payload["created_at"])
        valid = (
            identifier == payload["id"]
            and created_at.tzinfo is not None
            and payload["origin"] in {"app1", "app2", "app3"}
        )
    except (KeyError, TypeError, ValueError, AttributeError):
        return None
    if not valid:
        return None
    return {key: payload[key] for key in ("id", "message", "origin", "created_at")}


def replicate_message(message):
    results = {}
    for peer in PEERS:
        name = urlparse(peer).hostname
        try:
            response = requests.post(
                f"{peer}/send",
                json=message,
                headers={"X-Replication": "true"},
                timeout=(2, 3),
                allow_redirects=False,
            )
            response.raise_for_status()
            confirmation = response.json()
            if (
                response.status_code not in (200, 201)
                or not isinstance(confirmation, dict)
                or confirmation.get("message") != message
                or confirmation.get("stored_by") != name
            ):
                raise ValueError("O destino não confirmou a mensagem esperada.")
            results[name] = "ok"
        except (requests.RequestException, ValueError) as error:
            results[name] = "erro"
            app.logger.warning("Falha ao replicar %s para %s: %s", message["id"], name, error)
    return results


@app.post("/send")
def send():
    if not request.is_json:
        return jsonify(error="Use Content-Type: application/json."), 415

    payload = request.get_json(silent=True)
    if not isinstance(payload, dict):
        return jsonify(error="Envie um objeto JSON válido."), 400

    text = payload.get("message")
    if not isinstance(text, str) or not text.strip() or len(text) > 4096:
        return jsonify(error="message deve ser um texto com 1 a 4096 caracteres e não pode ser vazio."), 400

    is_replica = request.headers.get("X-Replication") == "true"
    if is_replica:
        message = validate_replica(payload)
        if message is None:
            return jsonify(error="A cópia precisa de id UUID, origin e created_at com fuso horário."), 400
    else:
        message = {
            "id": str(uuid4()),
            "message": text,
            "origin": APP_NAME,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }

    inserted = store_message(message)
    if is_replica:
        # Uma cópia é apenas armazenada, sem novo envio aos vizinhos.
        return jsonify(stored_by=APP_NAME, message=message, duplicate=not inserted), 201 if inserted else 200

    replication = replicate_message(message)
    status = 201 if all(result == "ok" for result in replication.values()) else 202
    return jsonify(stored_by=APP_NAME, message=message, replication=replication), status


@app.get("/messages")
def messages():
    return jsonify(read_messages())


@app.errorhandler(MessageConflict)
def conflicting_message(error):
    return jsonify(error="Este id já foi usado por uma mensagem diferente."), 409


@app.errorhandler(OSError)
@app.errorhandler(json.JSONDecodeError)
def storage_error(error):
    app.logger.error("Falha ao acessar %s: %s", LOG_FILE, error)
    return jsonify(error="Não foi possível acessar o arquivo de mensagens."), 503


@app.errorhandler(413)
def oversized_request(error):
    return jsonify(error="O corpo da requisição excede 64 KiB."), 413


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)
