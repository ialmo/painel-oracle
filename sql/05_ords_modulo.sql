-- =====================================================================
-- 05 - API REST no ORDS
-- Executar como PAINEL_MON no PDB FREEPDB1, DEPOIS que o container do
-- ORDS terminou a instalação (o pacote ORDS precisa existir no banco).
--   docker exec -i <container> sqlplus painel_mon/PainelMon123@//localhost:1521/FREEPDB1 < sql/05_ords_modulo.sql
--   (ou: bash scripts/configurar.sh, que roda 01 a 05 na ordem)
--
-- Resultado: http://localhost:8181/ords/painel/monitor/...
--
--   GET  /health                 status da API e horário do banco
--   GET  /stats/instancia        instância, banco e container      (1 linha)
--   GET  /stats/resumo           números dos cards                  (1 linha)
--   GET  /stats/metricas         estatísticas gerais (V$SYSMETRIC)
--   GET  /stats/sessoes          sessões por usuário e status
--   GET  /stats/sessoes/ativas   o que cada sessão ativa está fazendo
--   GET  /stats/bloqueios        quem bloqueia quem
--   GET  /stats/waits/agora      esperas do momento
--   GET  /stats/waits/acumulados top waits desde o startup
--   GET  /stats/sql              SQLs mais custosos
--   GET  /stats/tablespaces      uso dos tablespaces
--   GET  /stats/historico        linha do tempo (?minutos=30)
--   GET  /carga/status           situação da carga de laboratório   (1 linha)
--   POST /carga/iniciar          body JSON {"perfil":"MEDIA","minutos":3}
--   POST /carga/parar
--
-- Observação: os endpoints são públicos (sem autenticação) porque é um
-- laboratório local. Em produção usaríamos privilégios/OAuth do ORDS.
-- =====================================================================
WHENEVER SQLERROR EXIT FAILURE
SET ECHO ON

DECLARE
  c_modulo CONSTANT VARCHAR2(30) := 'monitor';

  -- GET que devolve uma lista: {"items":[ {...}, {...} ]}
  PROCEDURE get_lista(p_padrao IN VARCHAR2, p_sql IN VARCHAR2) IS
  BEGIN
    ORDS.DEFINE_TEMPLATE(p_module_name => c_modulo, p_pattern => p_padrao);
    ORDS.DEFINE_HANDLER(
      p_module_name    => c_modulo,
      p_pattern        => p_padrao,
      p_method         => 'GET',
      p_source_type    => ORDS.source_type_collection_feed,
      p_items_per_page => 0,   -- 0 = sem paginação, devolve tudo
      p_source         => p_sql);
  END get_lista;

  -- GET que devolve um único objeto: {...}
  PROCEDURE get_objeto(p_padrao IN VARCHAR2, p_sql IN VARCHAR2) IS
  BEGIN
    ORDS.DEFINE_TEMPLATE(p_module_name => c_modulo, p_pattern => p_padrao);
    ORDS.DEFINE_HANDLER(
      p_module_name => c_modulo,
      p_pattern     => p_padrao,
      p_method      => 'GET',
      p_source_type => ORDS.source_type_query_one_row,
      p_source      => p_sql);
  END get_objeto;

  -- POST que executa um bloco PL/SQL
  PROCEDURE post_plsql(p_padrao IN VARCHAR2, p_plsql IN VARCHAR2) IS
  BEGIN
    ORDS.DEFINE_TEMPLATE(p_module_name => c_modulo, p_pattern => p_padrao);
    ORDS.DEFINE_HANDLER(
      p_module_name => c_modulo,
      p_pattern     => p_padrao,
      p_method      => 'POST',
      p_source_type => ORDS.source_type_plsql,
      p_source      => p_plsql);
  END post_plsql;

BEGIN
  -- Publica o schema: /ords/painel/...
  ORDS.ENABLE_SCHEMA(
    p_enabled             => TRUE,
    p_schema              => 'PAINEL_MON',
    p_url_mapping_type    => 'BASE_PATH',
    p_url_mapping_pattern => 'painel',
    p_auto_rest_auth      => FALSE);

  -- DEFINE_MODULE substitui o módulo se ele já existir (script re-executável)
  ORDS.DEFINE_MODULE(
    p_module_name    => c_modulo,
    p_base_path      => 'monitor/',
    p_items_per_page => 0,
    p_status         => 'PUBLISHED',
    p_comments       => 'Painel Oracle - estatísticas atuais do banco');

  get_objeto('health', q'[
    SELECT 'UP'                                        AS status,
           TO_CHAR(SYSDATE, 'DD/MM/YYYY HH24:MI:SS')   AS horario_banco,
           SYS_CONTEXT('USERENV', 'CON_NAME')          AS container
    FROM   dual]');

  get_objeto('stats/instancia', 'SELECT * FROM vw_instancia');
  get_objeto('stats/resumo',    'SELECT * FROM vw_resumo');

  get_lista('stats/metricas',
            'SELECT * FROM vw_metricas_sistema ORDER BY metrica');
  get_lista('stats/sessoes',
            'SELECT * FROM vw_sessoes_resumo ORDER BY total DESC, usuario, status');
  get_lista('stats/sessoes/ativas',  'SELECT * FROM vw_sessoes_ativas');
  get_lista('stats/bloqueios',       'SELECT * FROM vw_bloqueios');
  get_lista('stats/waits/agora',     'SELECT * FROM vw_esperas_agora');
  get_lista('stats/waits/acumulados','SELECT * FROM vw_waits_acumulados');
  get_lista('stats/sql',             'SELECT * FROM vw_sql_top');
  get_lista('stats/tablespaces',     'SELECT * FROM vw_tablespaces');

  -- :minutos vem da query string (?minutos=30); padrão 30, máximo 24 h
  get_lista('stats/historico', q'[
    SELECT horario, sessoes_usuario, sessoes_ativas, sessoes_bloqueadas,
           aas, host_cpu_pct, execucoes_seg, transacoes_seg
    FROM   vw_historico
    WHERE  coletado_em >= SYSTIMESTAMP
                          - NUMTODSINTERVAL(LEAST(NVL(TO_NUMBER(:minutos), 30), 1440), 'MINUTE')
    ORDER  BY coletado_em]');

  get_objeto('carga/status', 'SELECT * FROM carga_lab.vw_carga_status');

  -- :perfil e :minutos vêm do corpo JSON do POST
  post_plsql('carga/iniciar', q'[
    BEGIN
      carga_lab.pkg_carga.iniciar(p_perfil  => :perfil,
                                  p_minutos => TO_NUMBER(:minutos));
      OWA_UTIL.MIME_HEADER('application/json', TRUE);
      HTP.P('{"ok":true,"acao":"iniciar"}');
    END;]');

  post_plsql('carga/parar', q'[
    BEGIN
      carga_lab.pkg_carga.parar;
      OWA_UTIL.MIME_HEADER('application/json', TRUE);
      HTP.P('{"ok":true,"acao":"parar"}');
    END;]');

  -- Origens liberadas no navegador. O painel servido pelo próprio ORDS
  -- (porta 8181) é a forma recomendada; 5500 é para quem preferir
  -- "python -m http.server 5500" ou o Live Server do VS Code.
  ORDS.SET_MODULE_ORIGINS_ALLOWED(
    p_module_name     => c_modulo,
    p_origins_allowed => 'http://localhost:8181,http://127.0.0.1:8181,'
                      || 'http://localhost:5500,http://127.0.0.1:5500');

  COMMIT;
END;
/

-- Conferência: templates publicados
SELECT t.uri_template, h.method, h.source_type
FROM   user_ords_templates t
JOIN   user_ords_handlers  h ON h.template_id = t.id
ORDER  BY t.uri_template, h.method;

SET ECHO OFF
PROMPT >>> 05 concluído. Teste: curl http://localhost:8181/ords/painel/monitor/health
PROMPT >>> Painel:        http://localhost:8181/painel/index.html
