-- =====================================================================
-- 02 - Views de monitoramento
-- Executar como PAINEL_MON no PDB FREEPDB1.
--   docker exec -i <container> sqlplus painel_mon/PainelMon123@//localhost:1521/FREEPDB1 < sql/02_views_monitoramento.sql
--   (ou: bash scripts/configurar.sh, que roda 01 a 05 na ordem)
--
-- Ideia: cada métrica do painel vira uma VIEW com nomes de colunas em
-- português. O ORDS (script 05) só faz "SELECT * FROM view", então toda
-- a lógica SQL fica aqui, num lugar só, fácil de mostrar em sala.
-- =====================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON

-- ---------------------------------------------------------------------
-- Instância + banco + container atual (1 linha)
-- Fontes: V$INSTANCE, V$DATABASE, SYS_CONTEXT('USERENV','CON_NAME')
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_instancia AS
SELECT i.instance_name                                  AS instancia,
       i.host_name                                      AS host,
       i.version_full                                   AS versao,
       i.status                                         AS status_instancia,
       i.database_status                                AS status_banco,
       TO_CHAR(i.startup_time, 'DD/MM/YYYY HH24:MI:SS') AS iniciada_em,
       ROUND((SYSDATE - i.startup_time) * 24, 1)        AS uptime_horas,
       d.name                                           AS banco,
       d.open_mode                                      AS modo_abertura,
       d.log_mode                                       AS modo_log,
       SYS_CONTEXT('USERENV', 'CON_NAME')               AS container_atual
FROM   v$instance i
CROSS  JOIN v$database d;

-- ---------------------------------------------------------------------
-- Resumo numérico para os cards (1 linha)
-- Fontes: V$SESSION (contagens) e V$SYSMETRIC (taxas do último minuto)
-- A própria sessão que consulta é excluída para não "sujar" o número
-- de sessões ativas.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_resumo AS
SELECT (SELECT COUNT(*)
        FROM   v$session
        WHERE  type = 'USER'
        AND    sid <> SYS_CONTEXT('USERENV', 'SID'))            AS sessoes_usuario,
       (SELECT COUNT(*)
        FROM   v$session
        WHERE  type = 'USER'
        AND    status = 'ACTIVE'
        AND    sid <> SYS_CONTEXT('USERENV', 'SID'))            AS sessoes_ativas,
       (SELECT COUNT(*)
        FROM   v$session
        WHERE  type = 'USER'
        AND    blocking_session IS NOT NULL
        AND    event LIKE 'enq:%')                              AS sessoes_bloqueadas,
       (SELECT ROUND(MAX(value), 2)
        FROM   v$sysmetric
        WHERE  group_id = 2
        AND    metric_name = 'Average Active Sessions')         AS aas,
       (SELECT ROUND(MAX(value), 1)
        FROM   v$sysmetric
        WHERE  group_id = 2
        AND    metric_name = 'Host CPU Utilization (%)')        AS host_cpu_pct,
       (SELECT ROUND(MAX(value), 1)
        FROM   v$sysmetric
        WHERE  group_id = 2
        AND    metric_name = 'Executions Per Sec')              AS execucoes_seg,
       (SELECT ROUND(MAX(value), 2)
        FROM   v$sysmetric
        WHERE  group_id = 2
        AND    metric_name = 'User Transaction Per Sec')        AS transacoes_seg,
       TO_CHAR(SYSDATE, 'DD/MM/YYYY HH24:MI:SS')                AS medido_em
FROM   dual;

-- ---------------------------------------------------------------------
-- Estatísticas gerais do sistema (lista)
-- Fonte: V$SYSMETRIC, grupo 2 = médias do último intervalo de 60 s
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_metricas_sistema AS
SELECT metric_name                    AS metrica,
       ROUND(MAX(value), 2)           AS valor,
       metric_unit                    AS unidade,
       TO_CHAR(MAX(end_time), 'HH24:MI:SS') AS medido_ate
FROM   v$sysmetric
WHERE  group_id = 2
AND    metric_name IN ('Average Active Sessions',
                       'Database Time Per Sec',
                       'CPU Usage Per Sec',
                       'Host CPU Utilization (%)',
                       'Executions Per Sec',
                       'User Transaction Per Sec',
                       'User Commits Per Sec',
                       'Logons Per Sec',
                       'Physical Reads Per Sec',
                       'Logical Reads Per Sec',
                       'Buffer Cache Hit Ratio',
                       'Database Wait Time Ratio',
                       'Database CPU Time Ratio')
GROUP  BY metric_name, metric_unit;

-- ---------------------------------------------------------------------
-- Sessões por usuário e status
-- Fonte: V$SESSION (somente sessões de usuário, sem processos de fundo)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_sessoes_resumo AS
SELECT username   AS usuario,
       status,
       COUNT(*)   AS total
FROM   v$session
WHERE  type = 'USER'
AND    username IS NOT NULL
AND    sid <> SYS_CONTEXT('USERENV', 'SID')
GROUP  BY username, status;

-- ---------------------------------------------------------------------
-- O que cada sessão ATIVA está fazendo AGORA
-- STATE = 'WAITING'  -> está esperando o EVENT
-- STATE <> 'WAITING' -> está usando CPU
-- LAST_CALL_ET       -> segundos desde que a chamada atual começou
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_sessoes_ativas AS
SELECT s.sid,
       s.serial#                                           AS serial,
       s.username                                          AS usuario,
       s.machine                                           AS maquina,
       s.program                                           AS programa,
       s.module                                            AS modulo,
       s.sql_id,
       CASE WHEN s.state = 'WAITING' THEN s.event      ELSE 'Em CPU' END AS atividade,
       CASE WHEN s.state = 'WAITING' THEN s.wait_class ELSE 'CPU'    END AS classe,
       s.last_call_et                                      AS segundos_ativa,
       s.blocking_session                                  AS bloqueada_por
FROM   v$session s
WHERE  s.type = 'USER'
AND    s.status = 'ACTIVE'
AND    s.sid <> SYS_CONTEXT('USERENV', 'SID')
ORDER  BY s.last_call_et DESC
FETCH  FIRST 20 ROWS ONLY;

-- ---------------------------------------------------------------------
-- Bloqueios: quem está esperando por quem
-- Fonte: V$SESSION.BLOCKING_SESSION + auto-join em V$SESSION
-- Filtro "enq:%" = esperas por enqueue (locks), ex.:
--   enq: TX - row lock contention -> duas sessões querendo a mesma linha
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_bloqueios AS
SELECT w.sid                          AS sid_bloqueada,
       w.username                     AS usuario_bloqueado,
       w.module                       AS modulo_bloqueado,
       w.event                        AS evento,
       w.last_call_et                 AS segundos_esperando,
       w.sql_id                       AS sql_bloqueado,
       b.sid                          AS sid_bloqueador,
       b.serial#                      AS serial_bloqueador,
       b.username                     AS usuario_bloqueador,
       b.module                       AS modulo_bloqueador,
       b.status                       AS status_bloqueador,
       NVL(b.sql_id, b.prev_sql_id)   AS sql_bloqueador
FROM   v$session w
JOIN   v$session b ON b.sid = w.blocking_session
WHERE  w.blocking_session IS NOT NULL
AND    w.event LIKE 'enq:%'
ORDER  BY w.last_call_et DESC;

-- ---------------------------------------------------------------------
-- Esperas AGORA: agrupa as sessões ativas pelo que estão esperando
-- (foto do momento - muda a cada atualização)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_esperas_agora AS
SELECT evento,
       classe,
       COUNT(*) AS sessoes
FROM  (SELECT CASE WHEN state = 'WAITING' THEN event      ELSE 'Em CPU' END AS evento,
              CASE WHEN state = 'WAITING' THEN wait_class ELSE 'CPU'    END AS classe
       FROM   v$session
       WHERE  type = 'USER'
       AND    status = 'ACTIVE'
       AND    sid <> SYS_CONTEXT('USERENV', 'SID')
       AND    NOT (state = 'WAITING' AND wait_class = 'Idle'))
GROUP  BY evento, classe
ORDER  BY sessoes DESC;

-- ---------------------------------------------------------------------
-- Waits ACUMULADOS desde o startup (top 10, sem a classe Idle)
-- Fonte: V$SYSTEM_EVENT. Os números só crescem: mostram a história,
-- não o momento. Para o momento, use vw_esperas_agora.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_waits_acumulados AS
SELECT event                                                AS evento,
       wait_class                                           AS classe,
       total_waits                                          AS total_esperas,
       ROUND(time_waited_micro / 1e6, 2)                    AS segundos_esperados,
       ROUND(time_waited_micro / NULLIF(total_waits, 0) / 1000, 2) AS media_ms
FROM   v$system_event
WHERE  wait_class <> 'Idle'
ORDER  BY time_waited_micro DESC
FETCH  FIRST 10 ROWS ONLY;

-- ---------------------------------------------------------------------
-- SQLs mais custosos (top 10 por tempo total)
-- Fonte: V$SQLAREA (estatísticas acumuladas por SQL_ID)
-- Exclui SQL interno (SYS), do ORDS e do próprio painel.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_sql_top AS
SELECT sql_id,
       parsing_schema_name                                   AS schema_sql,
       executions                                            AS execucoes,
       ROUND(elapsed_time / 1e6, 2)                          AS tempo_total_s,
       ROUND(cpu_time / 1e6, 2)                              AS cpu_s,
       ROUND(elapsed_time / NULLIF(executions, 0) / 1000, 1) AS ms_por_execucao,
       buffer_gets                                           AS leituras_logicas,
       disk_reads                                            AS leituras_fisicas,
       rows_processed                                        AS linhas,
       SUBSTR(sql_text, 1, 400)                              AS texto_sql
FROM   v$sqlarea
WHERE  parsing_schema_name NOT IN ('SYS', 'PAINEL_MON', 'ORDS_METADATA', 'ORDS_PUBLIC_USER')
ORDER  BY elapsed_time DESC
FETCH  FIRST 10 ROWS ONLY;

-- ---------------------------------------------------------------------
-- Uso dos tablespaces
-- Fonte: DBA_TABLESPACE_USAGE_METRICS (em blocos) x DBA_TABLESPACES
-- maximo_mb já considera o autoextend (tamanho máximo possível).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_tablespaces AS
SELECT m.tablespace_name                                       AS tablespace,
       t.contents                                              AS tipo,
       t.status,
       ROUND(m.used_space      * t.block_size / 1048576, 1)    AS usado_mb,
       ROUND(m.tablespace_size * t.block_size / 1048576, 1)    AS maximo_mb,
       ROUND(m.used_percent, 1)                                AS percentual_uso
FROM   dba_tablespace_usage_metrics m
JOIN   dba_tablespaces t ON t.tablespace_name = m.tablespace_name
ORDER  BY m.used_percent DESC;

-- Conferência rápida
SELECT * FROM vw_instancia;
SELECT * FROM vw_resumo;

SET ECHO OFF
PROMPT >>> 02 concluído. Próximo: 03_historico_scheduler.sql (como PAINEL_MON)
