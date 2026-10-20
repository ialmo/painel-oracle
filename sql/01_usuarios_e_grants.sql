-- =====================================================================
-- 01 - Usuários e permissões
-- Executar como SYS (AS SYSDBA) conectado no PDB FREEPDB1.
--   docker exec -i <container> sqlplus "sys/<senha>@//localhost:1521/FREEPDB1 as sysdba" < sql/01_usuarios_e_grants.sql
--   (ou: bash scripts/configurar.sh, que roda 01 a 05 na ordem)
--
-- Por que SYS? Só o dono das views V$ (SYS) consegue conceder SELECT
-- nelas a outro usuário. O SYSTEM lê, mas não pode repassar.
--
-- ATENÇÃO: o script recria os usuários (DROP ... CASCADE). Rodar de novo
-- apaga views, histórico e o módulo ORDS: depois rode os scripts 02 a 05.
-- =====================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON

ALTER SESSION SET CONTAINER = FREEPDB1;

-- ---------------------------------------------------------------------
-- PAINEL_MON: dono das views de monitoramento, do histórico e do
-- módulo REST publicado no ORDS. Só tem LEITURA nas views do sistema.
-- ---------------------------------------------------------------------
DROP USER IF EXISTS painel_mon CASCADE;

CREATE USER painel_mon IDENTIFIED BY "PainelMon123"
  DEFAULT TABLESPACE users
  QUOTA 50M ON users;

GRANT CREATE SESSION, CREATE VIEW, CREATE TABLE,
      CREATE PROCEDURE, CREATE JOB TO painel_mon;

-- Grants DIRETOS (não via role): views e procedures só enxergam
-- privilégios concedidos diretamente ao dono.
GRANT SELECT ON sys.v_$instance                  TO painel_mon;
GRANT SELECT ON sys.v_$database                  TO painel_mon;
GRANT SELECT ON sys.v_$session                   TO painel_mon;
GRANT SELECT ON sys.v_$system_event              TO painel_mon;
GRANT SELECT ON sys.v_$sqlarea                   TO painel_mon;
GRANT SELECT ON sys.v_$sysmetric                 TO painel_mon;
GRANT SELECT ON sys.dba_tablespaces              TO painel_mon;
GRANT SELECT ON sys.dba_tablespace_usage_metrics TO painel_mon;

-- ---------------------------------------------------------------------
-- CARGA_LAB: schema de laboratório que gera atividade no banco
-- (consultas pesadas, CPU e bloqueios) para o painel ter o que mostrar.
-- ---------------------------------------------------------------------
DROP USER IF EXISTS carga_lab CASCADE;

CREATE USER carga_lab IDENTIFIED BY "CargaLab123"
  DEFAULT TABLESPACE users
  QUOTA 200M ON users;

-- CREATE JOB: a carga roda em jobs do DBMS_SCHEDULER (uma sessão por job)
GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW,
      CREATE PROCEDURE, CREATE JOB TO carga_lab;

SELECT username, account_status, default_tablespace
FROM   dba_users
WHERE  username IN ('PAINEL_MON', 'CARGA_LAB');

SET ECHO OFF
PROMPT >>> 01 concluído. Próximo: 02_views_monitoramento.sql (como PAINEL_MON)
