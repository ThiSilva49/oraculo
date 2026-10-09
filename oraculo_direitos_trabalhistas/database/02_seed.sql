-- =====================================================================
-- Dados iniciais (desenvolvimento) — Oráculo dos Direitos Trabalhistas
-- =====================================================================

-- Admin de desenvolvimento. TROQUE A SENHA antes de qualquer deploy.
-- O hash é gerado com bcrypt pelo próprio Postgres (pgcrypto).
INSERT INTO administradores (nome, email, senha_hash, perfil)
VALUES ('Administrador', 'admin@oraculo.local', crypt('trocar-esta-senha', gen_salt('bf', 12)), 'ADMIN');

-- Temas (baseados nos capítulos usuais da cartilha do TRT4)
INSERT INTO temas (nome, slug, descricao, ordem_exibicao) VALUES
  ('Contrato de trabalho',     'contrato-de-trabalho', 'Carteira assinada, experiência, tipos de contrato',          1),
  ('Jornada e horas extras',   'jornada',              'Horário de trabalho, intervalos, horas extras, banco de horas', 2),
  ('Salário e remuneração',    'salario',              'Salário mínimo, descontos, adicionais, 13º salário',        3),
  ('Férias',                   'ferias',               'Período aquisitivo, terço constitucional, venda de férias', 4),
  ('Rescisão e demissão',      'rescisao',             'Aviso prévio, verbas rescisórias, justa causa',             5),
  ('FGTS e seguro-desemprego', 'fgts',                 'Depósitos, saque, multa de 40%, seguro-desemprego',         6),
  ('Saúde e segurança',        'saude-seguranca',      'Insalubridade, periculosidade, acidente de trabalho',       7),
  ('Gestante e família',       'gestante-familia',     'Licença-maternidade, paternidade, estabilidade',            8);

-- Perguntas sugeridas na página inicial (RF02)
INSERT INTO perguntas_sugeridas (tema_id, texto, ordem_exibicao)
SELECT t.id, x.texto, x.ordem
FROM (VALUES
  ('jornada',  'Quantas horas posso trabalhar por dia?',                1),
  ('jornada',  'Como funciona o pagamento de hora extra?',              2),
  ('ferias',   'Posso vender parte das minhas férias?',                 1),
  ('rescisao', 'O que recebo se for demitido sem justa causa?',         1),
  ('rescisao', 'Quanto tempo de aviso prévio eu tenho que cumprir?',    2),
  ('fgts',     'Em quais situações posso sacar o FGTS?',                1),
  ('gestante-familia', 'Grávida pode ser demitida?',                    1),
  ('contrato-de-trabalho', 'O que é contrato de experiência?',          1)
) AS x(slug, texto, ordem)
JOIN temas t ON t.slug = x.slug;

-- Fonte principal citada no documento da Sprint 01
INSERT INTO fontes (titulo, orgao, tipo, url, criado_por)
VALUES (
  'Cartilha de Direitos e Obrigações no Trabalho',
  'Tribunal Regional do Trabalho da 4ª Região (TRT4)',
  'CARTILHA',
  NULL,  -- preencher com o link oficial do PDF
  (SELECT id FROM administradores WHERE email = 'admin@oraculo.local')
);

-- Os trechos (com embedding) são inseridos pelo script de ingestão do RAG,
-- que lê o PDF, divide em pedaços e grava em "trechos".
