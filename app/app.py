"""
CitizenTech - Zeladoria Cidadã
-------------------------------
Aplicação web simples para moradores registrarem e acompanharem problemas do
bairro (buracos, iluminação, lixo, calçadas, alagamentos).

Esta é a aplicação hospedada pela infraestrutura Linux da disciplina de
Operating Systems. Toda a configuração vem de VARIÁVEIS DE AMBIENTE definidas
pelo script de provisionamento (/etc/citizentech/app.env):

    APP_ENV, APP_HOST, APP_PORT, DATABASE_PATH, SECRET_KEY, LOG_DIR

Dados: somente dados SIMULADOS (nenhum dado pessoal real).
"""
import os
import socket
import sqlite3
import time
from datetime import datetime

from flask import Flask, flash, g, jsonify, redirect, render_template, request, url_for

APP_VERSION = "1.0.0"
STARTED_AT = time.time()

APP_ENV = os.environ.get("APP_ENV", "development")
DB_PATH = os.environ.get(
    "DATABASE_PATH", os.path.join(os.path.dirname(os.path.abspath(__file__)), "citizentech-dev.db")
)

app = Flask(__name__)
app.config["SECRET_KEY"] = os.environ.get("SECRET_KEY", "dev-somente-local")

CATEGORIAS = {
    "buraco": "Buraco na via",
    "iluminacao": "Iluminação pública apagada",
    "lixo": "Lixo ou entulho acumulado",
    "calcada": "Calçada danificada",
    "alagamento": "Ponto de alagamento",
    "outro": "Outro problema",
}
STATUS = {"aberta": "Aberta", "andamento": "Em andamento", "resolvida": "Resolvida"}
PROXIMO_STATUS = {"aberta": "andamento", "andamento": "resolvida"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS ocorrencias (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    categoria  TEXT NOT NULL,
    bairro     TEXT NOT NULL,
    endereco   TEXT NOT NULL,
    descricao  TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'aberta',
    criada_em  TEXT NOT NULL
);
"""

# Dados simulados (não representam pessoas ou registros reais)
SEED = [
    ("buraco", "Lins de Vasconcelos", "Rua Vergueiro, altura do nº 2000", "Buraco grande na faixa da direita, carros desviando bruscamente.", "aberta"),
    ("iluminacao", "Aclimação", "Praça perto do parque", "Três postes apagados há uma semana, praça fica escura à noite.", "andamento"),
    ("lixo", "Cambuci", "Esquina próxima ao mercado", "Entulho de obra descartado na calçada.", "aberta"),
    ("calcada", "Paulista", "Calçada em frente ao ponto de ônibus", "Piso solto dificulta a passagem de cadeira de rodas.", "resolvida"),
    ("alagamento", "Ipiranga", "Rua próxima ao córrego", "Rua alaga em chuvas fortes, bueiro entupido.", "aberta"),
]


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(DB_PATH, timeout=10)
        g.db.row_factory = sqlite3.Row
    return g.db


@app.teardown_appcontext
def close_db(_exc):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db():
    """Cria o banco e insere dados simulados. Seguro com vários workers."""
    os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10, isolation_level=None)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("BEGIN IMMEDIATE")  # serializa a inicialização entre workers
        conn.execute(SCHEMA)
        (total,) = conn.execute("SELECT COUNT(*) FROM ocorrencias").fetchone()
        if total == 0:
            agora = datetime.now().isoformat(timespec="seconds")
            conn.executemany(
                "INSERT INTO ocorrencias (categoria, bairro, endereco, descricao, status, criada_em) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                [(*row, agora) for row in SEED],
            )
        conn.execute("COMMIT")
    finally:
        conn.close()


def validar(dados):
    erros = []
    if dados.get("categoria") not in CATEGORIAS:
        erros.append("Escolha uma categoria válida.")
    for campo, nome, minimo in (("bairro", "Bairro", 2), ("endereco", "Endereço/referência", 5), ("descricao", "Descrição", 10)):
        valor = (dados.get(campo) or "").strip()
        if len(valor) < minimo:
            erros.append(f"{nome}: informe ao menos {minimo} caracteres.")
        if len(valor) > 500:
            erros.append(f"{nome}: máximo de 500 caracteres.")
    return erros


def inserir(dados):
    db = get_db()
    cur = db.execute(
        "INSERT INTO ocorrencias (categoria, bairro, endereco, descricao, criada_em) VALUES (?, ?, ?, ?, ?)",
        (
            dados["categoria"],
            dados["bairro"].strip(),
            dados["endereco"].strip(),
            dados["descricao"].strip(),
            datetime.now().isoformat(timespec="seconds"),
        ),
    )
    db.commit()
    return cur.lastrowid


def estatisticas():
    db = get_db()
    linhas = db.execute("SELECT status, COUNT(*) AS n FROM ocorrencias GROUP BY status").fetchall()
    stats = {s: 0 for s in STATUS}
    for linha in linhas:
        stats[linha["status"]] = linha["n"]
    stats["total"] = sum(stats.values())
    return stats


# ---------------------------------------------------------------- páginas ---
@app.get("/")
def index():
    filtro = request.args.get("status", "")
    sql, params = "SELECT * FROM ocorrencias", []
    if filtro in STATUS:
        sql += " WHERE status = ?"
        params.append(filtro)
    sql += " ORDER BY id DESC LIMIT 100"
    ocorrencias = get_db().execute(sql, params).fetchall()
    return render_template(
        "index.html",
        ocorrencias=ocorrencias,
        stats=estatisticas(),
        categorias=CATEGORIAS,
        status=STATUS,
        filtro=filtro,
        host=socket.gethostname(),
        env=APP_ENV,
        version=APP_VERSION,
    )


@app.post("/ocorrencias")
def criar_form():
    erros = validar(request.form)
    if erros:
        for erro in erros:
            flash(erro, "erro")
        return redirect(url_for("index") + "#registrar")
    novo_id = inserir(request.form)
    flash(f"Ocorrência nº {novo_id} registrada. Obrigado por ajudar o seu bairro!", "ok")
    return redirect(url_for("index"))


@app.post("/ocorrencias/<int:oid>/avancar")
def avancar(oid):
    db = get_db()
    row = db.execute("SELECT status FROM ocorrencias WHERE id = ?", (oid,)).fetchone()
    if row and row["status"] in PROXIMO_STATUS:
        novo = PROXIMO_STATUS[row["status"]]
        db.execute("UPDATE ocorrencias SET status = ? WHERE id = ?", (novo, oid))
        db.commit()
        flash(f"Ocorrência nº {oid} agora está: {STATUS[novo]}.", "ok")
    return redirect(url_for("index"))


# -------------------------------------------------------------------- API ---
@app.get("/api/ocorrencias")
def api_listar():
    rows = get_db().execute("SELECT * FROM ocorrencias ORDER BY id DESC").fetchall()
    return jsonify([dict(r) for r in rows])


@app.post("/api/ocorrencias")
def api_criar():
    dados = request.get_json(silent=True) or {}
    erros = validar(dados)
    if erros:
        return jsonify({"erros": erros}), 400
    return jsonify({"id": inserir(dados), "status": "aberta"}), 201


@app.get("/api/estatisticas")
def api_estatisticas():
    return jsonify(estatisticas())


@app.get("/api/info")
def api_info():
    """Mostra as variáveis de ambiente usadas (sem segredos) - útil na demonstração."""
    return jsonify(
        {
            "app": "CitizenTech - Zeladoria Cidadã",
            "versao": APP_VERSION,
            "ambiente": APP_ENV,
            "hostname": socket.gethostname(),
            "pid": os.getpid(),
            "usuario_uid": os.getuid(),
            "app_host": os.environ.get("APP_HOST"),
            "app_port": os.environ.get("APP_PORT"),
            "database_path": DB_PATH,
            "log_dir": os.environ.get("LOG_DIR"),
            "secret_key_configurada": bool(os.environ.get("SECRET_KEY")),
            "uptime_segundos": int(time.time() - STARTED_AT),
        }
    )


@app.get("/health")
def health():
    """Usado pelo monitoramento e pelo watchdog para saber se a aplicação está saudável."""
    try:
        get_db().execute("SELECT 1").fetchone()
        db_ok = True
    except sqlite3.Error:
        db_ok = False
    body = {
        "status": "ok" if db_ok else "degradado",
        "banco": "ok" if db_ok else "erro",
        "versao": APP_VERSION,
        "hostname": socket.gethostname(),
        "uptime_segundos": int(time.time() - STARTED_AT),
    }
    return jsonify(body), (200 if db_ok else 503)


@app.template_filter("data_br")
def data_br(valor):
    try:
        return datetime.fromisoformat(valor).strftime("%d/%m/%Y %H:%M")
    except (TypeError, ValueError):
        return valor


init_db()

if __name__ == "__main__":
    # Execução local de desenvolvimento: python app.py
    app.run(host=os.environ.get("APP_HOST", "127.0.0.1"), port=int(os.environ.get("APP_PORT", "8000")), debug=False)
