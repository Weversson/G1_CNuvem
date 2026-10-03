# Sistema de mensagens distribuído

Aplicação em Python com Flask, executada em três containers. Cada serviço recebe mensagens por HTTP, grava no seu arquivo e envia uma cópia aos outros dois serviços.

## Características

* API REST para envio e consulta de mensagens.
* Replicação por HTTP entre as três instâncias, usando os nomes dos serviços na rede Docker.
* Arquivos de mensagens independentes em um volume compartilhado.
* Identificação por UUID, controle de cópias duplicadas e bloqueio de arquivo durante a gravação.
* Persistência dos dados após reiniciar ou recriar os containers.
* Verificação de disponibilidade dos serviços e testes automatizados.

## Estrutura

```text
G1_CNuvem/
├── app/
│   ├── app.py
│   ├── requirements.txt
│   └── Dockerfile
├── docker-compose.yml
├── test.sh
└── README.md
```

## Como executar

### 1. Conferir os requisitos

São necessários Git, Docker Engine e o plugin Docker Compose. O teste também usa Bash e Python 3 no computador. Os exemplos de requisição usam `curl`. As portas 5001, 5002 e 5003 precisam estar livres.

### 2. Clonar o repositório

```bash
git clone https://github.com/Weversson/G1_CNuvem.git
cd G1_CNuvem
```

Os próximos comandos devem ser executados nessa pasta.

### 3. Conferir o Docker

Com o Docker instalado e o serviço iniciado, confira as versões:

```bash
docker version
docker compose version
```

Se ainda precisar preparar o ambiente, siga a [documentação de instalação do Docker no Fedora](https://docs.docker.com/engine/install/fedora/). O plugin Docker Compose também precisa estar instalado.

Caso o acesso ao Docker exija permissão administrativa, use `sudo docker` nos comandos abaixo e `sudo ./test.sh` para executar os testes.

### 4. Iniciar os serviços

Construa a imagem e inicie os containers:

```bash
docker compose up -d --build --wait
docker compose ps
```

O comando constrói a imagem, cria os três containers e aguarda os serviços ficarem disponíveis. Nas próximas execuções, `docker compose up -d` também inicia o projeto.

| Serviço | Endereço no computador | Endereço na rede dos containers |
| --- | --- | --- |
| app1 | http://localhost:5001 | http://app1:5000 |
| app2 | http://localhost:5002 | http://app2:5000 |
| app3 | http://localhost:5003 | http://app3:5000 |

As portas são publicadas em `127.0.0.1`. A comunicação entre os containers usa a rede bridge `mensagens_net` e os nomes definidos no Compose.

### 5. Enviar e consultar uma mensagem

Envie uma mensagem para `app1`:

```bash
curl -i -X POST http://localhost:5001/send \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello"}'
```

Consulte as mensagens em `app2`:

```bash
curl http://localhost:5002/messages
```

Exemplo de retorno:

```json
[
  {
    "id": "b0c228a4-e10c-42c2-a6b0-502f0a8c569a",
    "message": "hello",
    "origin": "app1",
    "created_at": "2026-10-03T12:00:00+00:00"
  }
]
```

O identificador e o horário são gerados no envio. A mesma mensagem fica disponível em `http://localhost:5003/messages`. Também é possível enviar mensagens pelas portas 5002 e 5003.

### 6. Executar os testes

```bash
./test.sh
```

O script verifica envio, replicação, persistência, entradas inválidas, duplicatas e falha de um destino. Ao concluir, mantém os serviços em execução. A seção de teste automático descreve cada verificação.

## API

### POST /send

Recebe um objeto JSON com o campo `message`. O valor deve ser um texto de até 4096 caracteres e não pode estar vazio ou conter apenas espaços. O corpo completo da requisição tem limite de 64 KiB.

A resposta contém `stored_by`, com o serviço que recebeu o envio, `message`, com o registro salvo, e `replication`, com o resultado para cada destino. Em um envio por `app1`, a confirmação completa é:

```json
{
  "app2": "ok",
  "app3": "ok"
}
```

Esse objeto aparece no campo `replication` da resposta.

| Código HTTP | Significado |
| --- | --- |
| 201 | Mensagem salva e confirmada pelos dois destinos, ou uma nova cópia recebida. |
| 200 | Cópia já existente, sem nova gravação. |
| 202 | Mensagem salva na origem, mas pelo menos um destino não confirmou o recebimento. |
| 400 | JSON ou campos inválidos. |
| 409 | Uma cópia usa um identificador existente com conteúdo diferente. |
| 413 | Corpo da requisição maior que 64 KiB. |
| 415 | Requisição sem o tipo de conteúdo JSON. |
| 503 | Falha ao acessar o arquivo de mensagens. |

### GET /messages

Retorna uma lista com todas as mensagens do arquivo da instância consultada, na ordem em que foram gravadas. Se ainda não houver mensagens, retorna `[]`.

## Replicação e armazenamento

Ao receber um envio, a aplicação gera um UUID e um horário em UTC. Ela salva o registro antes de enviar as cópias por `requests`, usando os endereços da variável `PEERS`.

As cópias preservam o identificador, o texto, a origem e o horário. O cabeçalho interno `X-Replication: true` indica que o destino deve apenas armazenar a mensagem. Isso encerra a replicação e evita um ciclo de envios. O cliente que inicia uma mensagem não precisa desse cabeçalho.

Cada destino confirma o registro recebido. A origem confere o conteúdo e o nome do serviço na resposta antes de marcar a entrega como `ok`. Uma cópia repetida não gera outra linha. Um mesmo identificador com conteúdo diferente é rejeitado.

O volume nomeado `mensagens` é montado em `/data` nos três containers:

```text
/data/
├── app1.log
├── app2.log
└── app3.log
```

Cada arquivo usa JSON Lines: uma mensagem completa por linha. Esses arquivos são os logs de mensagens e também o armazenamento da aplicação. Cada instância consulta apenas seu próprio arquivo, mesmo tendo acesso ao volume inteiro. Assim, a consulta em outro serviço verifica a entrega da cópia por HTTP.

As operações usam bloqueios de arquivo para coordenar leituras e gravações simultâneas. Após cada inclusão, `flush` e `fsync` enviam os dados ao armazenamento antes da confirmação.

Para conferir os arquivos pelo mesmo container:

```bash
docker compose exec app1 ls -l /data
docker compose exec app1 cat /data/app1.log
docker compose exec app1 cat /data/app2.log
docker compose exec app1 cat /data/app3.log
```

Os logs de acesso HTTP e os erros de replicação são enviados à saída do container:

```bash
docker compose logs -f
```

## Teste automático

Execute na raiz do repositório:

```bash
./test.sh
```

O script constrói a imagem, sobe os serviços e verifica:

1. Envio por cada instância e recebimento nas outras duas.
2. Rejeição de JSON inválido, mensagens vazias e corpos acima do limite.
3. Tratamento de cópias repetidas e conflitos de identificador.
4. Seis envios simultâneos, incluindo gravações nos mesmos arquivos.
5. Presença dos três logs no volume compartilhado e integridade das mensagens.
6. Retorno de falha parcial com `app3` parado, preservando a mensagem em `app1` e `app2`.
7. Persistência após `docker compose down` e nova criação dos containers.

O teste acrescenta mensagens identificadas por execução e interrompe brevemente os serviços desse projeto. Ele preserva o volume e deixa os três containers em execução ao terminar. Não exige `jq`, bibliotecas Python no computador ou instalação manual das dependências da aplicação.

Se tudo estiver correto, a última linha será:

```text
Todos os testes passaram. Os três serviços continuam em execução.
```

Os sete grupos de testes foram executados com sucesso no Fedora 44, usando Docker Engine 29.8.2 e Docker Compose 5.6.0.

## Parar e manter os dados

```bash
docker compose down
docker compose up -d --wait
```

O volume permanece entre as execuções. Para remover os containers e apagar todas as mensagens, use explicitamente:

```bash
docker compose down -v
```

## Decisões e limites

A imagem usa Python slim, dependências diretas com versões fixadas e instalação sem cache do pip. Somente `app.py` e `requirements.txt` são copiados. O processo executa com usuário sem privilégios de root. O Gunicorn atende as requisições com oito threads por instância, e o Compose verifica a disponibilidade com um healthcheck.

O armazenamento em arquivos é adequado para pequenos volumes de mensagens. Os arquivos são lidos por inteiro, não há paginação nem rotação dos logs. Todos os containers dependem do mesmo host e do mesmo volume.

Cada envio tenta alcançar os dois destinos, com limite de tempo para conexão e resposta. Se um deles estiver indisponível, o retorno 202 informa a falha parcial. Não há fila de reenvio nem sincronização automática quando o destino volta. Nesse caso, os arquivos podem ficar diferentes. O teste de indisponibilidade verifica esse comportamento.

A API não possui autenticação. O cabeçalho de replicação apenas controla o encaminhamento das cópias. O acesso pelo computador fica limitado às portas locais configuradas no Compose.

## Referências

Documentação consultada para instalação e configuração:

* [Docker Engine no Fedora](https://docs.docker.com/engine/install/fedora/)
* [Configuração de serviços no Docker Compose](https://docs.docker.com/reference/compose-file/services/)
* [Flask com Gunicorn](https://flask.palletsprojects.com/en/stable/deploying/gunicorn/)
* [Requests](https://docs.python-requests.org/en/latest/)
