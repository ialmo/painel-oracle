-- =====================================================================
-- 03 - Histórico de métricas com DBMS_SCHEDULER
-- Executar como PAINEL_MON no PDB FREEPDB1 (depois do script 02).
--   docker exec -i <container> sqlplus painel_mon/PainelMon123@//localhost:1521/FREEPDB1 < sql/03_historico_scheduler.sql
--   (ou: bash scripts/configurar.sh, que roda 01 a 05 na ordem)
--
-- As V$ mostram só o "agora". Para o painel desenhar uma linha do tempo,
-- um job do próprio Oracle tira uma "foto" da VW_RESUMO a cada 15 s e
-- grava na tabela METRICAS_HIST. Fotos com mais de 1 dia são apagadas.
-- =====================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON

-- Remove o job anterior, se existir (para poder rodar o script de novo)
BEGIN
  DBMS_SCHEDULER.DROP_JOB(job_name => 'JOB_COLETA_METRICAS', force => TRUE);
EXCEPTION
  WHEN OTHERS THEN NULL;  -- ORA-27475: job não existe -> ok
END;
/

DROP TABLE IF EXISTS metricas_hist PURGE;

CREATE TABLE metricas_hist (
  coletado_em        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  sessoes_usuario    NUMBER,
  sessoes_ativas     NUMBER,
  sessoes_bloqueadas NUMBER,
  aas                NUMBER,
  host_cpu_pct       NUMBER,
  execucoes_seg      NUMBER,
  transacoes_seg     NUMBER,
  CONSTRAINT metricas_hist_pk PRIMARY KEY (coletado_em)
);

CREATE OR REPLACE PROCEDURE coletar_snapshot AS
BEGIN
  INSERT INTO metricas_hist (coletado_em, sessoes_usuario, sessoes_ativas,
                             sessoes_bloqueadas, aas, host_cpu_pct,
                             execucoes_seg, transacoes_seg)
  SELECT SYSTIMESTAMP, sessoes_usuario, sessoes_ativas,
         sessoes_bloqueadas, aas, host_cpu_pct,
         execucoes_seg, transacoes_seg
  FROM   vw_resumo;

  -- Retenção: mantém só as últimas 24 horas
  DELETE FROM metricas_hist
  WHERE  coletado_em < SYSTIMESTAMP - INTERVAL '1' DAY;

  COMMIT;
END coletar_snapshot;
/

BEGIN
  DBMS_SCHEDULER.CREATE_JOB(
    job_name        => 'JOB_COLETA_METRICAS',
    job_type        => 'STORED_PROCEDURE',
    job_action      => 'PAINEL_MON.COLETAR_SNAPSHOT',
    repeat_interval => 'FREQ=SECONDLY;INTERVAL=15',
    enabled         => TRUE,
    comments        => 'Painel Oracle: grava um snapshot da VW_RESUMO a cada 15 segundos');
END;
/

-- Linha do tempo lida pelo endpoint /stats/historico
CREATE OR REPLACE VIEW vw_historico AS
SELECT coletado_em,
       TO_CHAR(coletado_em, 'HH24:MI:SS') AS horario,
       sessoes_usuario,
       sessoes_ativas,
       sessoes_bloqueadas,
       aas,
       host_cpu_pct,
       execucoes_seg,
       transacoes_seg
FROM   metricas_hist;

-- Primeira coleta manual, para não esperar o job
EXEC coletar_snapshot

-- Conferência: o job deve aparecer como SCHEDULED
SELECT job_name, state, repeat_interval, last_start_date, run_count
FROM   user_scheduler_jobs;

SELECT * FROM vw_historico ORDER BY coletado_em;

SET ECHO OFF
PROMPT >>> 03 concluído. Próximo: 04_carga_lab.sql (como CARGA_LAB)
