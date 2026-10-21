# Painel Oracle — Dashboard de estatísticas com ORDS

Trabalho final · Grupo 1 · Oracle ADM — MBA em Engenharia de Dados (PUC Minas)

> **Integrante:** Ialmo Gontijo

Dashboard simples que mostra, em tempo quase real, o estado de um Oracle Free 23ai: instância, sessões, esperas, bloqueios, SQLs mais custosos e uso de tablespaces. Os dados saem das views administrativas do Oracle, viram API REST no **ORDS** e aparecem num painel HTML que se atualiza sozinho.

```text
Oracle Free 23ai (FREEPDB1)
  ├─ V$INSTANCE, V$DATABASE, V$SESSION, V$SYSTEM_EVENT,
  │  V$SQLAREA, V$SYSMETRIC, DBA_TABLESPACE_USAGE_METRICS
  │        │
  │        ▼
  ├─ views VW_* no schema PAINEL_MON  ──►  job DBMS_SCHEDULER (15 s) ──► METRICAS_HIST
  │        │
  │        ▼
  └─ ORDS: módulo REST "monitor"  (GET /stats/*, POST /carga/*)
           │
           ▼
     Painel HTML/CSS/JS servido pelo próprio ORDS  (atualiza a cada 5/10/30 s)
```

## O que tem de diferente

| Recurso | Por que importa |
| --- | --- |
| **Views `VW_*` como contrato** | Toda a lógica SQL fica no banco, numa view por métrica. O ORDS só faz `SELECT * FROM view`, e na apresentação dá para abrir a view e mostrar de onde vem cada número. |
| **Histórico com `DBMS_SCHEDULER`** | As `V$` só mostram o agora. Um job grava uma foto a cada 15 s, e o painel desenha a linha do tempo. |
| **Bloqueios em destaque** | `/stats/bloqueios` mostra quem bloqueia quem (`BLOCKING_SESSION`) e o painel exibe um alerta vermelho. |
| **Waits "agora" × "acumulados"** | Mostra a diferença entre o momento (`V$SESSION`) e a história desde o startup (`V$SYSTEM_EVENT`). |
| **Carga gerada dentro do Oracle** | O botão **Gerar carga** chama um `POST` no ORDS que cria jobs PL/SQL: full scans, CPU e duas sessões disputando a mesma linha. Não precisa de nenhum script externo. |
| **ORDS serve o próprio painel** | O HTML fica no *doc root* do ORDS, com mesma origem da API. Não precisa de servidor web extra nem de configurar CORS. |
| **Explicação em cada bloco** | Cada painel tem um "ⓘ Como ler" com a interpretação da métrica. |

## Estrutura

```text
painel-oracle/
├── README.md
├── docker/
│   ├── compose.yaml            ORDS (conecta num Oracle já existente)
│   ├── compose.banco.yaml      opcional: sobe também um Oracle Free 23ai
│   └── .env.example            qual Oracle usar, senha, portas
├── sql/
│   ├── 01_usuarios_e_grants.sql    SYS      → cria PAINEL_MON e CARGA_LAB + grants nas V$
│   ├── 02_views_monitoramento.sql  PAINEL_MON → views VW_*
│   ├── 03_historico_scheduler.sql  PAINEL_MON → tabela METRICAS_HIST + job
│   ├── 04_carga_lab.sql            CARGA_LAB  → tabelas + PKG_CARGA
│   ├── 05_ords_modulo.sql          PAINEL_MON → módulo REST no ORDS
│   └── consultas.sql               consultas "puras" para estudo no DBeaver
├── web/
│   ├── index.html
│   ├── style.css
│   └── app.js
├── scripts/
│   ├── configurar.sh           roda os SQL 01→05 na ordem
│   └── mock_ords.py            API falsa para mexer no visual sem Oracle
└── docs/
    ├── metricas.md             o que cada métrica significa e de onde vem
    └── roteiro_apresentacao.md
```

## Pré-requisitos

- Docker Desktop (ou Docker Engine) com Docker Compose
- **Um Oracle 23ai rodando em Docker** (por exemplo, o container das aulas). Se não tiver, o projeto sobe um (veja a opção B).
- Opcional: DBeaver/SQL Developer para explorar as consultas

## Como rodar

### 1. Configurar qual Oracle usar

```bash
cd docker
cp .env.example .env
```

Edite `docker/.env` com os dados do seu container:

| Variável | O que colocar | Como descobrir |
| --- | --- | --- |
| `DB_CONTAINER` | nome do container do Oracle | `docker ps` |
| `ORACLE_PWD` | senha do SYS | `docker inspect <container>`, variável `ORACLE_PASSWORD` (imagem gvenzl) ou `ORACLE_PWD` (imagem oficial) |
| `DB_PORT` | porta publicada no seu computador | `docker ps`, coluna PORTS (`0.0.0.0:1521->1521`) |

### 2. Subir o ORDS

**A) Já tenho um Oracle rodando** (caso mais comum):

```bash
docker compose up -d
docker compose logs -f ords   # espere "Iniciando ORDS" e o servidor no ar (CTRL+C para sair do log)
```

**B) Não tenho Oracle:** sobe um Oracle Free 23ai junto (~4 GB de download). No `.env`, use `DB_CONTAINER=painel-oracle-db`:

```bash
docker compose -f compose.yaml -f compose.banco.yaml up -d
```

Na primeira subida o ORDS se instala no banco (conectando como SYS), o que leva alguns minutos. Nas próximas, ele sobe direto.

### 3. Criar usuários, views, job e API

Da raiz do projeto (macOS, Linux ou Git Bash no Windows):

```bash
bash scripts/configurar.sh
```

O script lê o `docker/.env`, roda os SQL de 01 a 05 dentro do container do Oracle, espera o ORDS e testa a API.

Para rodar manualmente, cada arquivo é enviado pelo stdin para o `sqlplus` do container:

```bash
docker exec -i oracle-23ai-free sqlplus "sys/SUA_SENHA@//localhost:1521/FREEPDB1 as sysdba" < sql/01_usuarios_e_grants.sql
docker exec -i oracle-23ai-free sqlplus painel_mon/PainelMon123@//localhost:1521/FREEPDB1 < sql/02_views_monitoramento.sql
docker exec -i oracle-23ai-free sqlplus painel_mon/PainelMon123@//localhost:1521/FREEPDB1 < sql/03_historico_scheduler.sql
docker exec -i oracle-23ai-free sqlplus carga_lab/CargaLab123@//localhost:1521/FREEPDB1 < sql/04_carga_lab.sql
docker exec -i oracle-23ai-free sqlplus painel_mon/PainelMon123@//localhost:1521/FREEPDB1 < sql/05_ords_modulo.sql
```

Pelo DBeaver também funciona: abra os arquivos da pasta `sql/` e execute como script (Alt+X), conectado com o usuário indicado no cabeçalho de cada um (Host `localhost`, porta do `.env`, service `FREEPDB1`).

### 4. Abrir o painel

```text
http://localhost:8181/painel/index.html
```

Clique em **Gerar carga** e acompanhe sessões, esperas, bloqueios e o gráfico mudando.

## Endpoints

Base: `http://localhost:8181/ords/painel/monitor`

| Método | Caminho | Fonte | Retorno |
| --- | --- | --- | --- |
| GET | `/health` | `DUAL` | status da API, horário do banco |
| GET | `/stats/instancia` | `VW_INSTANCIA` | instância, banco, container (objeto) |
| GET | `/stats/resumo` | `VW_RESUMO` | números dos cards (objeto) |
| GET | `/stats/metricas` | `VW_METRICAS_SISTEMA` | estatísticas gerais |
| GET | `/stats/sessoes` | `VW_SESSOES_RESUMO` | sessões por usuário e status |
| GET | `/stats/sessoes/ativas` | `VW_SESSOES_ATIVAS` | o que cada sessão ativa faz |
| GET | `/stats/bloqueios` | `VW_BLOQUEIOS` | quem bloqueia quem |
| GET | `/stats/waits/agora` | `VW_ESPERAS_AGORA` | esperas do momento |
| GET | `/stats/waits/acumulados` | `VW_WAITS_ACUMULADOS` | top 10 desde o startup |
| GET | `/stats/sql` | `VW_SQL_TOP` | top 10 SQLs por tempo |
| GET | `/stats/tablespaces` | `VW_TABLESPACES` | uso dos tablespaces |
| GET | `/stats/historico?minutos=30` | `VW_HISTORICO` | linha do tempo |
| GET | `/carga/status` | `CARGA_LAB.VW_CARGA_STATUS` | situação da carga (objeto) |
| POST | `/carga/iniciar` | `PKG_CARGA.INICIAR` | body `{"perfil":"MEDIA","minutos":3}` |
| POST | `/carga/parar` | `PKG_CARGA.PARAR` | — |

Teste rápido:

```bash
curl http://localhost:8181/ords/painel/monitor/stats/resumo
curl -X POST -H "Content-Type: application/json" \
     -d '{"perfil":"LEVE","minutos":2}' \
     http://localhost:8181/ords/painel/monitor/carga/iniciar
```

## Usuários criados

| Usuário | Senha (lab) | Papel |
| --- | --- | --- |
| `PAINEL_MON` | `PainelMon123` | Dono das views, do histórico e do módulo ORDS. Só tem **SELECT** nas views do sistema (privilégio mínimo). |
| `CARGA_LAB` | `CargaLab123` | Tabelas `VENDAS` (300 mil linhas) e `ESTOQUE`, e o pacote `PKG_CARGA`. |

Os grants nas `V$` são **diretos** e não via role, porque views e procedures só enxergam privilégios concedidos diretamente ao dono.

## Desenvolvendo o visual sem Oracle

```bash
python3 scripts/mock_ords.py
# http://localhost:8181/painel/index.html
```

Ele responde nos mesmos caminhos e com os mesmos campos do ORDS real, com números aleatórios. O botão de carga também funciona. Use só com o ORDS real parado, porque a porta é a mesma.

## Problemas comuns

| Sintoma | Causa provável / solução |
| --- | --- |
| `docker compose up` falha no pull | Rode `docker login container-registry.oracle.com` (conta Oracle gratuita) e tente de novo. |
| Log do ORDS: `ORA-01017` / `invalid username/password` | `ORACLE_PWD` errado no `.env`. Corrija e rode `docker compose down -v && docker compose up -d`. |
| Log do ORDS: `IO Error` / `connection refused` | Porta errada (`DB_PORT`) ou o Oracle está parado. |
| Script 05 dá `PLS-00201: identifier 'ORDS.ENABLE_SCHEMA'` | O ORDS ainda não terminou de instalar. Espere o log (`docker compose logs -f ords`) e rode o `configurar.sh` de novo. |
| Painel abre, mas um bloco mostra erro | Rode o endpoint no navegador para ver a mensagem. Normalmente é um grant faltando, então rode o script 01 e depois 02 a 05. |
| `/ords/painel/...` dá 404 | O script 05 não rodou ou deu erro. Rode de novo como `PAINEL_MON`. |
| `/painel/index.html` dá 404 | O volume da pasta `web` não montou. Rode `docker compose up -d --force-recreate ords`. Alternativa: `cd web && python -m http.server 5500` e abra `http://localhost:5500` (o CORS para essa porta já está liberado). |
| "Estatísticas gerais" vazia | `V$SYSMETRIC` só tem valores 1 minuto após o startup. |
| Gráfico sem pontos | O job grava a cada 15 s. Confira com `SELECT job_name, state FROM user_scheduler_jobs;` como `PAINEL_MON`. |
| Precisa recomeçar do zero | Rode `bash scripts/configurar.sh` de novo: ele recria os usuários `PAINEL_MON` e `CARGA_LAB`. `docker compose down -v` apaga a configuração do ORDS (e o banco, na opção B). |

## Segurança (laboratório)

As senhas estão no código e os endpoints são públicos porque é um ambiente local de aula. Em produção usaríamos `.env` fora do Git, privilégios ORDS/OAuth nos módulos e não exporíamos o `POST /carga/*`.
