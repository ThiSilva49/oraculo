-- =====================================================================
-- Oráculo dos Direitos Trabalhistas — Banco de dados
-- Ciência da Computação 8NA — Kaleido Void Studios
--
-- SGBD: PostgreSQL 15+ com a extensão pgvector (busca semântica do RAG)
--
-- Rastreabilidade com o documento da Sprint 01:
--   RF01  acesso sem conta ............... sessoes (anônimas)
--   RF02  perguntas/temas sugeridos ...... temas, perguntas_sugeridas
--   RF03  pergunta livre ................. perguntas
--   RF04  RAG na base de conhecimento .... fontes, trechos (embedding)
--   RF05  resposta gerada ................ respostas
--   RF06  linguagem acessível ............ respostas.texto
--   RF07  informar a fonte ............... resposta_trechos
--   RF08  consultar conteúdo original .... fontes.url / trechos.conteudo
--   RF09  "não encontrei informação" ..... respostas.status = 'SEM_INFORMACAO'
--   RF10  conteúdo complementar .......... solicitacoes_conteudo
--   RF11  envio via WhatsApp ............. contatos_whatsapp, envios_whatsapp
--   RF12  acompanhar temas ............... inscricoes_tema
--   RF13  atualizações dos temas ......... atualizacoes_tema, envios_whatsapp
--   RF14  área administrativa ............ administradores, auditoria_admin
--   RNF03 LGPD ........................... consentimento, telefone mascarado,
--                                         view de auditoria sem dados pessoais
--   RNF04 autenticação do admin .......... administradores.senha_hash
--   RNF05 tempo de resposta .............. respostas.tempo_resposta_ms
--   RNF06 registro de erros .............. logs_erro
--   RNF08 aderência à base ............... resposta_trechos.similaridade,
--                                         avaliacoes_resposta
--   RNF09 custo operacional da IA ........ respostas.tokens_*, custo_estimado_usd
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS vector;     -- pgvector
CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

-- ---------------------------------------------------------------------
-- Tipos enumerados
-- ---------------------------------------------------------------------
CREATE TYPE canal_tipo          AS ENUM ('WEB', 'WHATSAPP');
CREATE TYPE fonte_tipo          AS ENUM ('CARTILHA', 'LEI', 'SUMULA', 'ARTIGO', 'OUTRO');
CREATE TYPE resposta_status     AS ENUM ('RESPONDIDA', 'SEM_INFORMACAO', 'ERRO');
CREATE TYPE solicitacao_status  AS ENUM ('PENDENTE', 'ENVIADA', 'FALHOU', 'CANCELADA');
CREATE TYPE envio_status        AS ENUM ('PENDENTE', 'ENVIADO', 'ENTREGUE', 'LIDO', 'FALHOU');
CREATE TYPE admin_perfil        AS ENUM ('ADMIN', 'EDITOR');
CREATE TYPE log_nivel           AS ENUM ('INFO', 'AVISO', 'ERRO', 'CRITICO');

-- Função genérica para manter atualizado_em
CREATE OR REPLACE FUNCTION fn_set_atualizado_em() RETURNS trigger AS $$
BEGIN
    NEW.atualizado_em := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
-- 1. ÁREA ADMINISTRATIVA (RF14, RNF04)
-- =====================================================================
CREATE TABLE administradores (
    id              BIGSERIAL PRIMARY KEY,
    nome            VARCHAR(120)  NOT NULL,
    email           VARCHAR(255)  NOT NULL,
    senha_hash      VARCHAR(255)  NOT NULL,              -- bcrypt/argon2, nunca texto puro
    perfil          admin_perfil  NOT NULL DEFAULT 'EDITOR',
    ativo           BOOLEAN       NOT NULL DEFAULT TRUE,
    ultimo_login_em TIMESTAMPTZ,
    criado_em       TIMESTAMPTZ   NOT NULL DEFAULT now(),
    atualizado_em   TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX ux_administradores_email ON administradores (lower(email));
CREATE TRIGGER trg_administradores_upd BEFORE UPDATE ON administradores
    FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();

-- =====================================================================
-- 2. BASE DE CONHECIMENTO (RF02, RF04, RF07, RF08, UC07)
-- =====================================================================
CREATE TABLE temas (
    id            SERIAL PRIMARY KEY,
    nome          VARCHAR(100) NOT NULL,
    slug          VARCHAR(100) NOT NULL UNIQUE,
    descricao     TEXT,
    icone         VARCHAR(50),
    ordem_exibicao SMALLINT    NOT NULL DEFAULT 0,
    ativo         BOOLEAN      NOT NULL DEFAULT TRUE,
    criado_em     TIMESTAMPTZ  NOT NULL DEFAULT now(),
    atualizado_em TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_temas_upd BEFORE UPDATE ON temas
    FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();

-- Documento de origem (ex.: Cartilha de Direitos e Obrigações no Trabalho — TRT4)
CREATE TABLE fontes (
    id               BIGSERIAL PRIMARY KEY,
    titulo           VARCHAR(255) NOT NULL,
    orgao            VARCHAR(120),                       -- ex.: TRT4
    tipo             fonte_tipo   NOT NULL DEFAULT 'CARTILHA',
    url              TEXT,                               -- link para o conteúdo original (RF08)
    arquivo_caminho  TEXT,                               -- caminho do PDF no storage
    versao           VARCHAR(30),
    data_publicacao  DATE,
    hash_conteudo    CHAR(64),                           -- SHA-256 do arquivo, evita reindexar igual
    ativo            BOOLEAN      NOT NULL DEFAULT TRUE,
    criado_por       BIGINT REFERENCES administradores (id) ON DELETE SET NULL,
    criado_em        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    atualizado_em    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_fontes_upd BEFORE UPDATE ON fontes
    FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();

-- Pedaços (chunks) da fonte com o vetor de embedding usado na busca do RAG
-- Dimensão 1536 = text-embedding-3-small (OpenAI). Ajuste se usar outro modelo.
CREATE TABLE trechos (
    id             BIGSERIAL PRIMARY KEY,
    fonte_id       BIGINT       NOT NULL REFERENCES fontes (id) ON DELETE CASCADE,
    tema_id        INT          REFERENCES temas (id) ON DELETE SET NULL,
    ordem          INT          NOT NULL,                -- posição do trecho dentro da fonte
    secao          VARCHAR(255),                         -- título/capítulo de onde veio
    pagina         INT,
    conteudo       TEXT         NOT NULL,
    qtd_tokens     INT,
    embedding      vector(1536),
    modelo_embedding VARCHAR(80),
    criado_em      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (fonte_id, ordem)
);
CREATE INDEX ix_trechos_fonte ON trechos (fonte_id);
CREATE INDEX ix_trechos_tema  ON trechos (tema_id);
-- Índice vetorial (similaridade por cosseno)
CREATE INDEX ix_trechos_embedding ON trechos USING hnsw (embedding vector_cosine_ops);
-- Busca textual complementar (busca híbrida)
CREATE INDEX ix_trechos_fts ON trechos USING gin (to_tsvector('portuguese', conteudo));

CREATE TABLE perguntas_sugeridas (
    id            SERIAL PRIMARY KEY,
    tema_id       INT          REFERENCES temas (id) ON DELETE CASCADE,
    texto         VARCHAR(300) NOT NULL,
    ordem_exibicao SMALLINT    NOT NULL DEFAULT 0,
    ativo         BOOLEAN      NOT NULL DEFAULT TRUE,
    criado_em     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- =====================================================================
-- 3. CONSULTAS DO USUÁRIO (RF01, RF03, RF05–RF09, UC01–UC03)
-- =====================================================================
-- Usuário não cria conta (RF01): a sessão é anônima e identificada por UUID
-- guardado no navegador (cookie/localStorage) ou pelo contato do WhatsApp.
CREATE TABLE sessoes (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    canal           canal_tipo  NOT NULL DEFAULT 'WEB',
    contato_id      BIGINT,                              -- FK adicionada abaixo
    dispositivo     VARCHAR(20),                         -- 'MOBILE', 'DESKTOP' (RNF01)
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now(),
    ultima_atividade_em TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE perguntas (
    id                    BIGSERIAL PRIMARY KEY,
    sessao_id             UUID        NOT NULL REFERENCES sessoes (id) ON DELETE CASCADE,
    texto                 TEXT        NOT NULL,
    pergunta_sugerida_id  INT         REFERENCES perguntas_sugeridas (id) ON DELETE SET NULL,
    tema_id               INT         REFERENCES temas (id) ON DELETE SET NULL,  -- tema identificado
    embedding             vector(1536),                  -- embedding da pergunta (cache)
    criado_em             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_perguntas_sessao ON perguntas (sessao_id);
CREATE INDEX ix_perguntas_criado ON perguntas (criado_em);
CREATE INDEX ix_perguntas_tema   ON perguntas (tema_id);

CREATE TABLE respostas (
    id                  BIGSERIAL PRIMARY KEY,
    pergunta_id         BIGINT          NOT NULL UNIQUE REFERENCES perguntas (id) ON DELETE CASCADE,
    texto               TEXT,                            -- NULL quando status = 'ERRO'
    status              resposta_status NOT NULL,
    modelo_llm          VARCHAR(80),
    tokens_entrada      INT,
    tokens_saida        INT,
    custo_estimado_usd  NUMERIC(10,6),                   -- RNF09
    tempo_resposta_ms   INT,                             -- RNF05
    criado_em           TIMESTAMPTZ     NOT NULL DEFAULT now(),
    CHECK (status = 'ERRO' OR texto IS NOT NULL)
);
CREATE INDEX ix_respostas_status ON respostas (status);

-- Quais trechos fundamentaram a resposta (RF07 / RF08 / UC03)
CREATE TABLE resposta_trechos (
    resposta_id   BIGINT  NOT NULL REFERENCES respostas (id) ON DELETE CASCADE,
    trecho_id     BIGINT  NOT NULL REFERENCES trechos (id) ON DELETE CASCADE,
    similaridade  REAL,                                  -- score do retrieval (0–1)
    posicao       SMALLINT NOT NULL,                     -- ranking 1, 2, 3...
    citado        BOOLEAN NOT NULL DEFAULT TRUE,         -- exibido como fonte ao usuário
    PRIMARY KEY (resposta_id, trecho_id)
);
CREATE INDEX ix_resposta_trechos_trecho ON resposta_trechos (trecho_id);

-- Feedback do usuário e/ou avaliação da equipe (PB12 — avaliação das respostas da IA)
CREATE TABLE avaliacoes_resposta (
    id              BIGSERIAL PRIMARY KEY,
    resposta_id     BIGINT      NOT NULL REFERENCES respostas (id) ON DELETE CASCADE,
    administrador_id BIGINT     REFERENCES administradores (id) ON DELETE SET NULL, -- NULL = usuário
    util            BOOLEAN,
    nota            SMALLINT CHECK (nota BETWEEN 1 AND 5),
    aderente_base   BOOLEAN,                             -- RNF08
    comentario      TEXT,
    criado_em       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX ix_avaliacoes_resposta ON avaliacoes_resposta (resposta_id);

-- =====================================================================
-- 4. WHATSAPP E ACOMPANHAMENTO DE TEMAS (RF10–RF13, UC04–UC06)
-- =====================================================================
CREATE TABLE contatos_whatsapp (
    id                  BIGSERIAL PRIMARY KEY,
    telefone_e164       VARCHAR(16)  NOT NULL UNIQUE,    -- ex.: +5551999998888
    nome                VARCHAR(120),                    -- opcional
    consentimento_em    TIMESTAMPTZ  NOT NULL,           -- LGPD: aceite explícito
    consentimento_texto_versao VARCHAR(20) NOT NULL,     -- versão do termo aceito
    revogado_em         TIMESTAMPTZ,                     -- opt-out ("SAIR")
    criado_em           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    atualizado_em       TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (telefone_e164 ~ '^\+[1-9][0-9]{7,14}$')
);
CREATE TRIGGER trg_contatos_upd BEFORE UPDATE ON contatos_whatsapp
    FOR EACH ROW EXECUTE FUNCTION fn_set_atualizado_em();

ALTER TABLE sessoes
    ADD CONSTRAINT fk_sessoes_contato
    FOREIGN KEY (contato_id) REFERENCES contatos_whatsapp (id) ON DELETE SET NULL;

-- UC04 / UC05: usuário pede material complementar sobre o assunto pesquisado
CREATE TABLE solicitacoes_conteudo (
    id            BIGSERIAL PRIMARY KEY,
    pergunta_id   BIGINT             NOT NULL REFERENCES perguntas (id) ON DELETE CASCADE,
    contato_id    BIGINT             REFERENCES contatos_whatsapp (id) ON DELETE SET NULL,
    canal         canal_tipo         NOT NULL,
    status        solicitacao_status NOT NULL DEFAULT 'PENDENTE',
    criado_em     TIMESTAMPTZ        NOT NULL DEFAULT now(),
    atendido_em   TIMESTAMPTZ,
    CHECK (canal <> 'WHATSAPP' OR contato_id IS NOT NULL)
);
CREATE INDEX ix_solicitacoes_status ON solicitacoes_conteudo (status);

-- UC06: usuário acompanha um tema
CREATE TABLE inscricoes_tema (
    id            BIGSERIAL PRIMARY KEY,
    contato_id    BIGINT      NOT NULL REFERENCES contatos_whatsapp (id) ON DELETE CASCADE,
    tema_id       INT         NOT NULL REFERENCES temas (id) ON DELETE CASCADE,
    criado_em     TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancelado_em  TIMESTAMPTZ
);
-- Só pode haver uma inscrição ativa por contato/tema
CREATE UNIQUE INDEX ux_inscricao_ativa ON inscricoes_tema (contato_id, tema_id)
    WHERE cancelado_em IS NULL;

-- Novidades publicadas pelo admin e enviadas aos inscritos (RF13)
CREATE TABLE atualizacoes_tema (
    id               BIGSERIAL PRIMARY KEY,
    tema_id          INT          NOT NULL REFERENCES temas (id) ON DELETE CASCADE,
    fonte_id         BIGINT       REFERENCES fontes (id) ON DELETE SET NULL,
    titulo           VARCHAR(200) NOT NULL,
    conteudo         TEXT         NOT NULL,
    publicado_em     TIMESTAMPTZ,                         -- NULL = rascunho
    criado_por       BIGINT       REFERENCES administradores (id) ON DELETE SET NULL,
    criado_em        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX ix_atualizacoes_tema ON atualizacoes_tema (tema_id, publicado_em);

-- Fila/histórico de mensagens enviadas (consumida pelo n8n — PB08/PB09)
CREATE TABLE envios_whatsapp (
    id                  BIGSERIAL PRIMARY KEY,
    contato_id          BIGINT       NOT NULL REFERENCES contatos_whatsapp (id) ON DELETE CASCADE,
    solicitacao_id      BIGINT       REFERENCES solicitacoes_conteudo (id) ON DELETE SET NULL,
    atualizacao_id      BIGINT       REFERENCES atualizacoes_tema (id) ON DELETE SET NULL,
    mensagem            TEXT         NOT NULL,
    status              envio_status NOT NULL DEFAULT 'PENDENTE',
    id_mensagem_externa VARCHAR(120),                     -- id retornado pela API do WhatsApp
    tentativas          SMALLINT     NOT NULL DEFAULT 0,
    erro                TEXT,
    criado_em           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    enviado_em          TIMESTAMPTZ,
    CHECK (solicitacao_id IS NOT NULL OR atualizacao_id IS NOT NULL)
);
CREATE INDEX ix_envios_pendentes ON envios_whatsapp (criado_em) WHERE status = 'PENDENTE';
-- Evita mandar a mesma atualização duas vezes para o mesmo contato
CREATE UNIQUE INDEX ux_envio_atualizacao ON envios_whatsapp (contato_id, atualizacao_id)
    WHERE atualizacao_id IS NOT NULL;

-- =====================================================================
-- 5. OBSERVABILIDADE E AUDITORIA (RNF06, UC07, UC08)
-- =====================================================================
CREATE TABLE logs_erro (
    id           BIGSERIAL PRIMARY KEY,
    nivel        log_nivel    NOT NULL DEFAULT 'ERRO',
    origem       VARCHAR(80)  NOT NULL,                  -- 'api', 'rag', 'llm', 'n8n', 'whatsapp'
    mensagem     TEXT         NOT NULL,
    detalhes     JSONB,                                  -- stack trace, payload (sem dados pessoais)
    pergunta_id  BIGINT       REFERENCES perguntas (id) ON DELETE SET NULL,
    criado_em    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX ix_logs_erro_criado ON logs_erro (criado_em DESC);
CREATE INDEX ix_logs_erro_origem ON logs_erro (origem, nivel);

-- Tudo o que o administrador altera na base fica registrado
CREATE TABLE auditoria_admin (
    id               BIGSERIAL PRIMARY KEY,
    administrador_id BIGINT       REFERENCES administradores (id) ON DELETE SET NULL,
    acao             VARCHAR(30)  NOT NULL,              -- 'CRIAR', 'ATUALIZAR', 'REMOVER', 'LOGIN'
    entidade         VARCHAR(60)  NOT NULL,              -- 'fontes', 'temas', ...
    entidade_id      VARCHAR(60),
    dados_anteriores JSONB,
    dados_novos      JSONB,
    criado_em        TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX ix_auditoria_admin ON auditoria_admin (administrador_id, criado_em DESC);

-- =====================================================================
-- 6. VIEWS
-- =====================================================================
-- UC08: auditar perguntas SEM expor dados sensíveis (RNF03 / LGPD).
-- Não traz sessão, telefone nem contato — só o conteúdo e métricas.
CREATE VIEW vw_auditoria_perguntas AS
SELECT
    p.id                     AS pergunta_id,
    p.criado_em,
    s.canal,
    t.nome                   AS tema,
    p.texto                  AS pergunta,
    r.status,
    r.texto                  AS resposta,
    r.modelo_llm,
    r.tempo_resposta_ms,
    r.custo_estimado_usd,
    (SELECT count(*) FROM resposta_trechos rt WHERE rt.resposta_id = r.id) AS qtd_fontes,
    (SELECT round(avg(rt.similaridade)::numeric, 3)
       FROM resposta_trechos rt WHERE rt.resposta_id = r.id)               AS similaridade_media
FROM perguntas p
JOIN sessoes s        ON s.id = p.sessao_id
LEFT JOIN temas t     ON t.id = p.tema_id
LEFT JOIN respostas r ON r.pergunta_id = p.id;

-- Fontes de cada resposta, prontas para o front exibir (RF07 / RF08)
CREATE VIEW vw_fontes_resposta AS
SELECT
    rt.resposta_id,
    rt.posicao,
    rt.similaridade,
    f.id     AS fonte_id,
    f.titulo AS fonte_titulo,
    f.orgao,
    f.url,
    tr.secao,
    tr.pagina,
    tr.conteudo AS trecho
FROM resposta_trechos rt
JOIN trechos tr ON tr.id = rt.trecho_id
JOIN fontes  f  ON f.id  = tr.fonte_id
WHERE rt.citado;

-- Painel do admin: volume, taxa de "sem informação", tempo e custo por dia
CREATE VIEW vw_metricas_diarias AS
SELECT
    date_trunc('day', p.criado_em)::date                          AS dia,
    count(*)                                                      AS perguntas,
    count(*) FILTER (WHERE r.status = 'SEM_INFORMACAO')           AS sem_informacao,
    count(*) FILTER (WHERE r.status = 'ERRO')                     AS erros,
    round(avg(r.tempo_resposta_ms))                               AS tempo_medio_ms,
    coalesce(sum(r.custo_estimado_usd), 0)                        AS custo_total_usd
FROM perguntas p
LEFT JOIN respostas r ON r.pergunta_id = p.id
GROUP BY 1;

-- Contatos aptos a receber mensagem (consentiram e não revogaram)
CREATE VIEW vw_inscritos_ativos AS
SELECT i.tema_id, c.id AS contato_id, c.telefone_e164
FROM inscricoes_tema i
JOIN contatos_whatsapp c ON c.id = i.contato_id
WHERE i.cancelado_em IS NULL
  AND c.revogado_em IS NULL;

-- =====================================================================
-- 7. FUNÇÕES DE APOIO
-- =====================================================================
-- Busca do RAG: devolve os k trechos mais próximos do embedding da pergunta.
-- Uso: SELECT * FROM fn_buscar_trechos('[0.01, ...]'::vector, 5, 0.75);
CREATE OR REPLACE FUNCTION fn_buscar_trechos(
    p_embedding        vector(1536),
    p_limite           INT  DEFAULT 5,
    p_similaridade_min REAL DEFAULT 0.0,
    p_tema_id          INT  DEFAULT NULL
)
RETURNS TABLE (
    trecho_id    BIGINT,
    fonte_id     BIGINT,
    fonte_titulo VARCHAR,
    secao        VARCHAR,
    pagina       INT,
    conteudo     TEXT,
    similaridade REAL
) AS $$
    SELECT * FROM (
        SELECT t.id AS trecho_id, f.id AS fonte_id, f.titulo AS fonte_titulo,
               t.secao, t.pagina, t.conteudo,
               (1 - (t.embedding <=> p_embedding))::REAL AS similaridade
        FROM trechos t
        JOIN fontes f ON f.id = t.fonte_id
        WHERE f.ativo
          AND t.embedding IS NOT NULL
          AND (p_tema_id IS NULL OR t.tema_id = p_tema_id)
        ORDER BY t.embedding <=> p_embedding
        LIMIT p_limite
    ) x
    WHERE x.similaridade >= p_similaridade_min;   -- se vazio → RF09 (SEM_INFORMACAO)
$$ LANGUAGE sql STABLE;

-- Ao publicar uma atualização de tema, enfileira a mensagem para todos os inscritos (RF13)
CREATE OR REPLACE FUNCTION fn_enfileirar_atualizacao() RETURNS trigger AS $$
BEGIN
    IF NEW.publicado_em IS NOT NULL
       AND (TG_OP = 'INSERT' OR OLD.publicado_em IS NULL) THEN
        INSERT INTO envios_whatsapp (contato_id, atualizacao_id, mensagem)
        SELECT v.contato_id, NEW.id, NEW.titulo || E'\n\n' || NEW.conteudo
        FROM vw_inscritos_ativos v
        WHERE v.tema_id = NEW.tema_id
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_atualizacao_publicada
    AFTER INSERT OR UPDATE OF publicado_em ON atualizacoes_tema
    FOR EACH ROW EXECUTE FUNCTION fn_enfileirar_atualizacao();
