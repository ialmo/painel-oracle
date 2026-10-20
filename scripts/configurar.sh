#!/usr/bin/env bash
# =====================================================================
# Roda os scripts SQL 01 a 05 na ordem certa, no container do Oracle.
# Lê as configurações de docker/.env (copie de docker/.env.example).
#
# Pré-requisitos:
#   - o Oracle rodando (seu container, ou o do compose.banco.yaml)
#   - "docker compose up -d" na pasta docker/ (sobe o ORDS)
#
# Uso (na raiz do projeto):
#   bash scripts/configurar.sh
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"

if [ -f "${RAIZ}/docker/.env" ]; then
  set -a; . "${RAIZ}/docker/.env"; set +a
else
  echo "ERRO: crie docker/.env a partir de docker/.env.example" >&2
  exit 1
fi

DB_CONTAINER="${DB_CONTAINER:?defina DB_CONTAINER em docker/.env}"
ORACLE_PWD="${ORACLE_PWD:?defina ORACLE_PWD em docker/.env}"
ORDS_URL="http://localhost:${ORDS_HOST_PORT:-8181}"
# Dentro do container o banco sempre escuta na 1521
PDB="//localhost:1521/${DB_SERVICE:-FREEPDB1}"

rodar_sql() {
  local conexao="$1" arquivo="$2"
  echo
  echo "==> ${arquivo}"
  # Envia o arquivo pelo stdin (não precisa copiar nada para o container)
  { cat "${RAIZ}/sql/${arquivo}"; printf '\nexit\n'; } \
    | docker exec -i "${DB_CONTAINER}" sqlplus -s -L "${conexao}"
}

echo "==> Verificando o container ${DB_CONTAINER}..."
if ! docker inspect "${DB_CONTAINER}" >/dev/null 2>&1; then
  echo "ERRO: container ${DB_CONTAINER} não existe. Confira DB_CONTAINER em docker/.env" >&2
  exit 1
fi

# Espera ficar healthy (se a imagem tiver healthcheck) ou ao menos rodando
until status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${DB_CONTAINER}")" \
      && { [ "${status}" = "healthy" ] || [ "${status}" = "running" ]; }; do
  printf '.'; sleep 10
done
echo " ${status}"

rodar_sql "sys/${ORACLE_PWD}@${PDB} as sysdba" 01_usuarios_e_grants.sql
rodar_sql "painel_mon/PainelMon123@${PDB}"     02_views_monitoramento.sql
rodar_sql "painel_mon/PainelMon123@${PDB}"     03_historico_scheduler.sql
rodar_sql "carga_lab/CargaLab123@${PDB}"       04_carga_lab.sql

echo
echo "==> Aguardando o ORDS responder em ${ORDS_URL}/ords/ (a 1a instalação demora)..."
until [ "$(curl -s -o /dev/null -w '%{http_code}' "${ORDS_URL}/ords/")" != "000" ]; do
  printf '.'; sleep 10
done
echo " ok"

rodar_sql "painel_mon/PainelMon123@${PDB}"     05_ords_modulo.sql

echo
echo "==> Teste da API:"
curl -s "${ORDS_URL}/ords/painel/monitor/health"; echo
echo
echo "Pronto! Abra o painel em: ${ORDS_URL}/painel/index.html"
