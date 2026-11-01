#!/usr/bin/env python3
import argparse
import getpass
import os
import sys
import time
from typing import Iterable, List

try:
    from dotenv import load_dotenv
except ImportError:
    load_dotenv = None

try:
    import praw
except ImportError:
    print("Este script precisa do pacote 'praw'.")
    print("Instale com: pip install praw python-dotenv")
    sys.exit(1)


DEFAULT_SUBREDDITS = [
    "Monitors",
    "Windows",
    "Linux",
    "KVM",
    "Hardware",
    "TechSupport",
]

POSTS = {
    "pt": {
        "title": "Samsung Odyssey G5: troca de HDMI/DisplayPort via software",
        "body": """Olá pessoal,

criei um pequeno projeto para controlar monitores Samsung via DDC/CI e trocar entre HDMI e DisplayPort sem precisar apertar o botão físico do monitor.

Ele suporta:
- Windows e Linux
- hotkeys
- bandeja/ícone
- KVM
- logs de debug

O projeto está em:
https://github.com/plugato/monitor-switch

Estou buscando testes e feedback em setups com Samsung Odyssey, KVM e multi-PC.

Se alguém usa Samsung Odyssey, monitor com DDC/CI ou setup com 2 PCs, seria ótimo testar e me dizer o que funciona melhor no seu caso.

Obrigado!""",
    },
    "en": {
        "title": "Samsung Odyssey G5: switch HDMI/DisplayPort from software",
        "body": """Hi everyone,

I built a small utility to control Samsung monitors over DDC/CI and switch between HDMI and DisplayPort without using the monitor buttons.

It supports:
- Windows and Linux
- hotkeys
- tray app
- KVM detection
- debug logs

Project:
https://github.com/plugato/monitor-switch

I'm looking for testers on Samsung Odyssey, KVM setups, and multi-PC setups.

If you use a Samsung monitor, a KVM, or a multi-PC setup, I'd appreciate feedback on what works for your hardware.

Thanks!""",
    },
}


def _placeholder_value(value: str | None) -> bool:
    if value is None:
        return True
    cleaned = value.strip()
    if not cleaned:
        return True
    normalized = cleaned.lower()
    placeholders = {
        "seu_client_id",
        "seu_client_secret",
        "seu_nome_de_usuario",
        "sua_senha",
        "your_client_id",
        "your_client_secret",
        "your_username",
        "your_password",
        "...",
    }
    return normalized in placeholders or normalized.startswith("seu_") or normalized.startswith("your_")


def _ask_for_credentials():
    values = {}
    print("\nVou pedir as credenciais do Reddit para continuar.")
    print("Essas informações serão usadas apenas para autenticar sua conta localmente.\n")

    for key in ["REDDIT_CLIENT_ID", "REDDIT_CLIENT_SECRET", "REDDIT_USERNAME", "REDDIT_PASSWORD"]:
        if key == "REDDIT_PASSWORD":
            value = getpass.getpass(f"{key}: ")
        else:
            value = input(f"{key}: ")
        values[key] = value.strip()

    for key, value in values.items():
        if value:
            os.environ[key] = value

    return values


def load_reddit():
    if load_dotenv is not None:
        load_dotenv(dotenv_path='.env', override=False)
    elif os.path.exists('.env'):
        print("Instale python-dotenv para carregar o .env automaticamente.")
        print("Comando: pip install python-dotenv")
        sys.exit(1)

    client_id = os.getenv("REDDIT_CLIENT_ID")
    client_secret = os.getenv("REDDIT_CLIENT_SECRET")
    username = os.getenv("REDDIT_USERNAME")
    password = os.getenv("REDDIT_PASSWORD")
    user_agent = os.getenv("REDDIT_USER_AGENT", "monitor-switch-post-bot")

    missing = []
    if _placeholder_value(client_id):
        missing.append("REDDIT_CLIENT_ID")
    if _placeholder_value(client_secret):
        missing.append("REDDIT_CLIENT_SECRET")
    if _placeholder_value(username):
        missing.append("REDDIT_USERNAME")
    if _placeholder_value(password):
        missing.append("REDDIT_PASSWORD")

    if missing:
        _ask_for_credentials()
        client_id = os.getenv("REDDIT_CLIENT_ID")
        client_secret = os.getenv("REDDIT_CLIENT_SECRET")
        username = os.getenv("REDDIT_USERNAME")
        password = os.getenv("REDDIT_PASSWORD")

    if _placeholder_value(client_id) or _placeholder_value(client_secret) or _placeholder_value(username) or _placeholder_value(password):
        print("As credenciais fornecidas ainda parecem inválidas.")
        print("Verifique o client ID, client secret, usuário e senha e tente novamente.")
        sys.exit(1)

    return praw.Reddit(
        client_id=client_id,
        client_secret=client_secret,
        username=username,
        password=password,
        user_agent=user_agent,
    )


def parse_subreddits(raw: str | None) -> List[str]:
    if not raw:
        return DEFAULT_SUBREDDITS

    values = [item.strip() for item in raw.split(",") if item.strip()]
    return values or DEFAULT_SUBREDDITS


def submit_posts(subreddits: Iterable[str], lang: str, dry_run: bool, delay: float):
    if lang not in POSTS:
        raise ValueError(f"Idioma inválido: {lang}. Use 'pt' ou 'en'.")

    reddit = load_reddit()
    post = POSTS[lang]

    for subreddit_name in subreddits:
        sub = reddit.subreddit(subreddit_name)

        print(f"Preparando post em r/{subreddit_name}...")
        print(f"Título: {post['title']}")

        if dry_run:
            print("[dry-run] não foi enviado")
        else:
            try:
                sub.submit(title=post["title"], selftext=post["body"])
                print(f"✅ Postado em r/{subreddit_name}")
            except Exception as exc:
                print(f"❌ Erro em r/{subreddit_name}: {exc}")

        if delay > 0 and subreddit_name != list(subreddits)[-1]:
            time.sleep(delay)


def main():
    parser = argparse.ArgumentParser(description="Posta automaticamente no Reddit usando o projeto monitor-switch.")
    parser.add_argument("--lang", choices=["pt", "en"], default="pt", help="Idioma do post.")
    parser.add_argument("--subreddits", default=None, help="Lista separada por vírgulas, ex.: Monitors,Windows,Linux")
    parser.add_argument("--dry-run", action="store_true", help="Mostra o que faria sem publicar.")
    parser.add_argument("--delay", type=float, default=30.0, help="Tempo em segundos entre posts.")
    args = parser.parse_args()

    subreddits = parse_subreddits(args.subreddits)
    submit_posts(subreddits, args.lang, args.dry_run, args.delay)


if __name__ == "__main__":
    main()
