"""
Мой первый Telegram-бот.

Что делает:
1. Отвечает на команду /start приветствием и показывает меню из кнопок.
2. По нажатию кнопки отвечает: приветствие, время или справка.
3. Повторяет любой текст, который ему напишут.

Запуск:
    ~/TGBOOT/venv/bin/python ~/TGBOOT/bot.py
"""

from datetime import datetime
from pathlib import Path

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

# Токен лежит в файле рядом со скриптом, чтобы не хранить его в коде
TOKEN_FILE = Path(__file__).parent / "token.txt"


def read_token() -> str:
    """Читает токен бота из файла token.txt и проверяет, что он похож на настоящий."""
    try:
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        raise SystemExit(
            f"Не найден файл {TOKEN_FILE}\n"
            "Создай его и вставь туда токен от @BotFather."
        )

    if ":" not in token:
        raise SystemExit(
            "В файле token.txt пока нет токена.\n"
            "Открой файл и замени текст-заглушку на токен от @BotFather.\n"
            "Токен выглядит так: 8123456789:AAH7xK..."
        )

    return token


def build_keyboard() -> InlineKeyboardMarkup:
    """Собирает меню из кнопок.

    callback_data — это «код» кнопки: когда её нажмут, бот получит именно эту строку
    и по ней поймёт, что делать.
    """
    return InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("Привет 👋", callback_data="hello"),
                InlineKeyboardButton("Который час 🕐", callback_data="time"),
            ],
            [
                InlineKeyboardButton("Что ты умеешь? ❓", callback_data="help"),
            ],
        ]
    )


async def start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Срабатывает на команду /start: здоровается и показывает меню."""
    user_name = update.effective_user.first_name
    print(f"[лог] команда /start от {user_name}")

    await update.message.reply_text(
        f"Привет, {user_name}! Я твой первый бот.\n"
        "Нажми кнопку — или напиши любой текст, я его повторю.",
        reply_markup=build_keyboard(),
    )


async def help_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Срабатывает на команду /help: снова показывает меню."""
    print("[лог] команда /help")
    await update.message.reply_text("Вот что я умею:", reply_markup=build_keyboard())


async def echo(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Повторяет текст, который прислал пользователь."""
    text = update.message.text
    print(f"[лог] пришло сообщение: {text}")

    await update.message.reply_text(f"Ты написал: {text}")


async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Срабатывает, когда пользователь нажал кнопку под сообщением."""
    query = update.callback_query

    # Обязательный шаг: сообщаем Telegram, что нажатие принято,
    # иначе на кнопке бесконечно крутится индикатор загрузки
    await query.answer()

    button_name = query.data
    print(f"[лог] нажата кнопка: {button_name}")

    if button_name == "hello":
        text = f"Привет, {query.from_user.first_name}! Рад тебя видеть."
    elif button_name == "time":
        current_time = datetime.now().strftime("%H:%M:%S")
        text = f"Сейчас {current_time}"
    else:
        text = (
            "Я умею немного:\n"
            "• здороваться по команде /start\n"
            "• показывать это меню\n"
            "• говорить время\n"
            "• повторять любой текст"
        )

    # Новый текст + снова кнопки, чтобы меню не исчезало
    await query.edit_message_text(text, reply_markup=build_keyboard())


def main() -> None:
    """Собирает бота из обработчиков и запускает его."""
    token = read_token()
    print("Токен прочитан, подключаюсь к Telegram...")

    application = Application.builder().token(token).build()

    # Какому событию какой обработчик соответствует
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("help", help_command))
    application.add_handler(CallbackQueryHandler(on_button))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, echo))

    print("Бот запущен. Открой Telegram и напиши своему боту /start")
    print("Остановить бота: Control + C в этом окне терминала.")

    application.run_polling()


if __name__ == "__main__":
    main()
