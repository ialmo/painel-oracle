-- =====================================================================
-- 04 - Gerador de carga de laboratório (100% dentro do Oracle)
-- Executar como CARGA_LAB no PDB FREEPDB1.
--   docker exec -i <container> sqlplus carga_lab/CargaLab123@//localhost:1521/FREEPDB1 < sql/04_carga_lab.sql
--   (ou: bash scripts/configurar.sh, que roda 01 a 05 na ordem)
--
-- Em vez de um script externo abrindo conexões, a carga é feita por
-- jobs do DBMS_SCHEDULER. Cada job = uma sessão Oracle trabalhando.
-- Tipos de trabalho:
--   CONSULTA  -> varre a tabela VENDAS (leituras lógicas, SQL no top)
--   CPU       -> laço de cálculo (sessões "Em CPU")
--   LOCK_DONO -> atualiza uma linha de ESTOQUE e segura o lock 10 s
--   LOCK_FILA -> tenta atualizar a MESMA linha e fica bloqueada
--                (evento "enq: TX - row lock contention")
--
-- Uso manual:
--   EXEC pkg_carga.iniciar('MEDIA', 3);   -- perfil LEVE | MEDIA | PESADA, minutos (1 a 15)
--   EXEC pkg_carga.parar;
-- Ou pelo botão "Gerar carga" do painel (POST no ORDS, script 05).
-- =====================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON

-- ---------------------------------------------------------------------
-- Tabelas
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS vendas PURGE;
DROP TABLE IF EXISTS estoque PURGE;
DROP TABLE IF EXISTS carga_controle PURGE;

CREATE TABLE vendas (
  id          NUMBER PRIMARY KEY,
  data_venda  DATE         NOT NULL,
  regiao      VARCHAR2(20) NOT NULL,
  produto     VARCHAR2(40) NOT NULL,
  quantidade  NUMBER       NOT NULL,
  valor       NUMBER(12,2) NOT NULL
);

-- 300 mil vendas fictícias (sem índice em regiao/produto de propósito:
-- as consultas da carga precisam fazer FULL TABLE SCAN)
INSERT /*+ APPEND */ INTO vendas
SELECT LEVEL,
       TRUNC(SYSDATE) - MOD(LEVEL, 730),
       CASE MOD(LEVEL, 5)
         WHEN 0 THEN 'Sudeste' WHEN 1 THEN 'Sul' WHEN 2 THEN 'Nordeste'
         WHEN 3 THEN 'Norte'   ELSE 'Centro-Oeste'
       END,
       'Produto ' || LPAD(MOD(LEVEL, 500), 3, '0'),
       MOD(LEVEL, 20) + 1,
       ROUND(DBMS_RANDOM.VALUE(10, 5000), 2)
FROM   dual
CONNECT BY LEVEL <= 300000;
COMMIT;

CREATE TABLE estoque (
  id      NUMBER PRIMARY KEY,
  produto VARCHAR2(40) NOT NULL,
  saldo   NUMBER       NOT NULL
);

INSERT INTO estoque
SELECT LEVEL, 'Produto ' || LPAD(LEVEL, 3, '0'), 1000
FROM   dual CONNECT BY LEVEL <= 5;
COMMIT;

-- Uma linha só: liga/desliga a carga e guarda até quando ela roda
CREATE TABLE carga_controle (
  id          NUMBER PRIMARY KEY CHECK (id = 1),
  ativo       CHAR(1) DEFAULT 'N' NOT NULL CHECK (ativo IN ('S', 'N')),
  perfil      VARCHAR2(10),
  iniciada_em TIMESTAMP,
  termina_em  TIMESTAMP
);
INSERT INTO carga_controle (id, ativo) VALUES (1, 'N');
COMMIT;

BEGIN
  DBMS_STATS.GATHER_SCHEMA_STATS(ownname => 'CARGA_LAB');
END;
/

-- ---------------------------------------------------------------------
-- Pacote de carga
-- ---------------------------------------------------------------------
CREATE OR REPLACE PACKAGE pkg_carga AS
  PROCEDURE iniciar(p_perfil IN VARCHAR2 DEFAULT 'MEDIA',
                    p_minutos IN NUMBER  DEFAULT 3);
  PROCEDURE parar;
  -- Chamado por cada job; não use diretamente
  PROCEDURE trabalhar(p_tipo IN VARCHAR2);
  FUNCTION jobs_rodando RETURN NUMBER;
END pkg_carga;
/

CREATE OR REPLACE PACKAGE BODY pkg_carga AS

  FUNCTION carga_ativa RETURN BOOLEAN IS
    v_ativo carga_controle.ativo%TYPE;
    v_fim   carga_controle.termina_em%TYPE;
  BEGIN
    SELECT ativo, termina_em INTO v_ativo, v_fim
    FROM   carga_controle WHERE id = 1;
    RETURN v_ativo = 'S' AND SYSTIMESTAMP < v_fim;
  END carga_ativa;

  FUNCTION jobs_rodando RETURN NUMBER IS
    v_total NUMBER;
  BEGIN
    SELECT COUNT(*) INTO v_total
    FROM   user_scheduler_running_jobs
    WHERE  job_name LIKE 'CARGA\_%' ESCAPE '\';
    RETURN v_total;
  END jobs_rodando;

  PROCEDURE criar_jobs(p_tipo IN VARCHAR2, p_qtde IN PLS_INTEGER) IS
  BEGIN
    FOR i IN 1 .. p_qtde LOOP
      DBMS_SCHEDULER.CREATE_JOB(
        job_name   => DBMS_SCHEDULER.GENERATE_JOB_NAME('CARGA_' || p_tipo || '_'),
        job_type   => 'PLSQL_BLOCK',
        job_action => 'BEGIN carga_lab.pkg_carga.trabalhar(''' || p_tipo || '''); END;',
        enabled    => TRUE,
        auto_drop  => TRUE,
        comments   => 'Painel Oracle - carga de laboratório');
    END LOOP;
  END criar_jobs;

  PROCEDURE parar IS
    TYPE t_nomes IS TABLE OF user_scheduler_jobs.job_name%TYPE;
    v_jobs t_nomes;
  BEGIN
    UPDATE carga_controle SET ativo = 'N' WHERE id = 1;
    COMMIT;

    -- Os jobs saem sozinhos ao ver ativo = 'N'. O DROP_JOB garante que
    -- nenhum fique para trás (force => tenta parar e depois remove).
    SELECT job_name BULK COLLECT INTO v_jobs
    FROM   user_scheduler_jobs
    WHERE  job_name LIKE 'CARGA\_%' ESCAPE '\';

    FOR i IN 1 .. v_jobs.COUNT LOOP
      BEGIN
        DBMS_SCHEDULER.DROP_JOB(job_name => v_jobs(i), force => TRUE);
      EXCEPTION
        WHEN OTHERS THEN NULL;  -- job já terminou e foi removido
      END;
    END LOOP;
  END parar;

  PROCEDURE iniciar(p_perfil IN VARCHAR2 DEFAULT 'MEDIA',
                    p_minutos IN NUMBER  DEFAULT 3) IS
    v_perfil    VARCHAR2(10) := UPPER(NVL(p_perfil, 'MEDIA'));
    v_minutos   NUMBER       := LEAST(GREATEST(NVL(p_minutos, 3), 1), 15);
    v_consultas PLS_INTEGER;
    v_cpu       PLS_INTEGER;
    v_fila      PLS_INTEGER;
  BEGIN
    CASE v_perfil
      WHEN 'LEVE'   THEN v_consultas := 2; v_cpu := 1; v_fila := 1;
      WHEN 'MEDIA'  THEN v_consultas := 3; v_cpu := 2; v_fila := 2;
      WHEN 'PESADA' THEN v_consultas := 5; v_cpu := 3; v_fila := 3;
      ELSE RAISE_APPLICATION_ERROR(-20001,
             'Perfil inválido: ' || v_perfil || '. Use LEVE, MEDIA ou PESADA.');
    END CASE;

    parar;  -- encerra uma carga anterior, se houver

    UPDATE carga_controle
    SET    ativo       = 'S',
           perfil      = v_perfil,
           iniciada_em = SYSTIMESTAMP,
           termina_em  = SYSTIMESTAMP + NUMTODSINTERVAL(v_minutos, 'MINUTE')
    WHERE  id = 1;
    COMMIT;

    criar_jobs('CONSULTA', v_consultas);
    criar_jobs('CPU',      v_cpu);
    criar_jobs('LOCK_DONO', 1);
    criar_jobs('LOCK_FILA', v_fila);
  END iniciar;

  PROCEDURE trabalhar(p_tipo IN VARCHAR2) IS
    v_qtde  NUMBER;
    v_total NUMBER;
    v_x     NUMBER := 0;
    v_prod  vendas.produto%TYPE;
  BEGIN
    -- MODULE aparece em V$SESSION: facilita achar a sessão no painel
    DBMS_APPLICATION_INFO.SET_MODULE('CARGA_LAB', p_tipo);

    WHILE carga_ativa LOOP
      CASE p_tipo
        WHEN 'CONSULTA' THEN
          -- Varredura completa + agregação: aparece no top de SQL
          v_prod := 'Produto ' || LPAD(TRUNC(DBMS_RANDOM.VALUE(0, 500)), 3, '0');
          SELECT COUNT(*), SUM(valor) INTO v_qtde, v_total
          FROM   vendas
          WHERE  produto = v_prod;

          SELECT MAX(total) INTO v_total
          FROM  (SELECT regiao, produto, SUM(valor * quantidade) AS total
                 FROM   vendas
                 GROUP  BY regiao, produto);

          DBMS_SESSION.SLEEP(DBMS_RANDOM.VALUE(0.2, 1));

        WHEN 'CPU' THEN
          -- Cálculo puro em PL/SQL: sessão fica "Em CPU"
          FOR i IN 1 .. 3000000 LOOP
            v_x := MOD(v_x + i * i, 9973);
          END LOOP;
          DBMS_SESSION.SLEEP(0.2);

        WHEN 'LOCK_DONO' THEN
          -- Pega o lock da linha 1 e demora para fazer COMMIT
          UPDATE estoque SET saldo = saldo - 1 WHERE id = 1;
          DBMS_SESSION.SLEEP(10);
          COMMIT;
          DBMS_SESSION.SLEEP(4);

        WHEN 'LOCK_FILA' THEN
          -- Mesma linha: fica esperando o LOCK_DONO liberar
          UPDATE estoque SET saldo = saldo + 1 WHERE id = 1;
          COMMIT;
          DBMS_SESSION.SLEEP(DBMS_RANDOM.VALUE(0.5, 2));
      END CASE;
    END LOOP;

    DBMS_APPLICATION_INFO.SET_MODULE(NULL, NULL);
  END trabalhar;

END pkg_carga;
/

-- ---------------------------------------------------------------------
-- Status da carga (lido pelo painel via ORDS)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_carga_status AS
SELECT CASE
         WHEN c.ativo = 'S' AND SYSTIMESTAMP < c.termina_em THEN 'RODANDO'
         WHEN pkg_carga.jobs_rodando > 0                    THEN 'FINALIZANDO'
         ELSE 'PARADA'
       END                                              AS situacao,
       c.perfil,
       TO_CHAR(c.iniciada_em, 'DD/MM/YYYY HH24:MI:SS')   AS iniciada_em,
       TO_CHAR(c.termina_em,  'DD/MM/YYYY HH24:MI:SS')   AS termina_em,
       CASE
         WHEN c.ativo = 'S' AND SYSTIMESTAMP < c.termina_em
         THEN ROUND((CAST(c.termina_em AS DATE) - SYSDATE) * 86400)
         ELSE 0
       END                                              AS segundos_restantes,
       pkg_carga.jobs_rodando                           AS jobs_rodando
FROM   carga_controle c;

-- O painel (PAINEL_MON) pode consultar o status e ligar/desligar a carga
GRANT SELECT  ON vw_carga_status TO painel_mon;
GRANT EXECUTE ON pkg_carga       TO painel_mon;

SELECT COUNT(*) AS vendas FROM vendas;
SELECT * FROM vw_carga_status;

SET ECHO OFF
PROMPT >>> 04 concluído. Próximo: 05_ords_modulo.sql (como PAINEL_MON)
