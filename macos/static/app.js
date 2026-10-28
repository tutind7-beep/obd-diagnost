// Параметры, которые показываем плитками
const TILES = [
  { key: "rpm", label: "Обороты", unit: "об/мин" },
  { key: "coolant", label: "Температура ОЖ", unit: "°C" },
  { key: "speed", label: "Скорость", unit: "км/ч" },
  { key: "voltage", label: "Напряжение", unit: "В" },
  { key: "fuel_trim_short", label: "Коррекция кратк.", unit: "%" },
  { key: "fuel_trim_long", label: "Коррекция долг.", unit: "%" },
  { key: "throttle", label: "Дроссель", unit: "%" },
  { key: "maf", label: "Расход воздуха", unit: "г/с" },
  { key: "intake_temp", label: "Темп. воздуха", unit: "°C" },
];

const MAX_POINTS = 40;
const REFRESH_MS = 2500;

// Симптомы для «диагностики по симптомам»
const SYMPTOM_CHOICES = [
  "троит двигатель",
  "дёргается при разгоне",
  "не заводится",
  "перегревается",
  "горит Check Engine",
  "потеря мощности",
  "повышенный расход топлива",
  "стук или шум из двигателя",
  "запах бензина",
  "вибрация на холостых оборотах",
  "дым из выхлопной трубы",
  "нестабильные холостые обороты",
];

const state = {
  timer: null,
  source: "demo",
  history: { rpm: [], coolant: [] },
  advice: { loading: false, lastCodesKey: "", lastText: "" },
  car: { make: "", model: "", year: "" },
};

const elements = {
  status: document.getElementById("status-text"),
  badge: document.getElementById("source-badge"),
  health: document.getElementById("health"),
  alert: document.getElementById("alert"),
  tiles: document.getElementById("tiles"),
  hints: document.getElementById("hints"),
  updated: document.getElementById("updated"),
  scenario: document.getElementById("scenario"),
  autoRefresh: document.getElementById("auto-refresh"),
  refreshBtn: document.getElementById("refresh-btn"),
  reportBtn: document.getElementById("report-btn"),
  rpmChart: document.getElementById("rpm-chart"),
  coolantChart: document.getElementById("coolant-chart"),
  adviceBtn: document.getElementById("advice-btn"),
  adviceStatus: document.getElementById("advice-status"),
  adviceText: document.getElementById("advice-text"),
  symptoms: document.getElementById("symptoms"),
  voiceBtn: document.getElementById("voice-btn"),
  voiceStatus: document.getElementById("voice-status"),
  speakBtn: document.getElementById("speak-btn"),
  make: document.getElementById("make-select"),
  model: document.getElementById("model-select"),
  year: document.getElementById("year"),
  vin: document.getElementById("vin"),
  vinBtn: document.getElementById("vin-btn"),
  vinStatus: document.getElementById("vin-status"),
  detectedInfo: document.getElementById("detected-info"),
  partBox: document.getElementById("part-box"),
  partName: document.getElementById("part-name"),
  partCost: document.getElementById("part-cost"),
  partLinks: document.getElementById("part-links"),
  symptomList: document.getElementById("symptom-list"),
  symptomBtn: document.getElementById("symptom-btn"),
  symptomStatus: document.getElementById("symptom-status"),
  symptomResult: document.getElementById("symptom-result"),
  dtcBtn: document.getElementById("dtc-btn"),
  dtcClearBtn: document.getElementById("dtc-clear-btn"),
  dtcStatus: document.getElementById("dtc-status"),
  dtcBlocks: document.getElementById("dtc-blocks"),
  adapterType: document.getElementById("adapter-type"),
  adapterList: document.getElementById("adapter-list"),
  adapterRefresh: document.getElementById("adapter-refresh"),
  adapterConnect: document.getElementById("adapter-connect"),
  adapterStatus: document.getElementById("adapter-status"),
  paramsBtn: document.getElementById("params-btn"),
  paramsStatus: document.getElementById("params-status"),
  paramsGroups: document.getElementById("params-groups"),
  tgChatId: document.getElementById("tg-chat-id"),
  tgLookupBtn: document.getElementById("tg-lookup-btn"),
  tgBtn: document.getElementById("tg-btn"),
  tgStatus: document.getElementById("tg-status"),
};

function loadCar() {
  try {
    const saved = JSON.parse(localStorage.getItem("obd-car") || "{}");
    return { make: saved.make || "", model: saved.model || "", year: saved.year || "" };
  } catch (error) {
    return { make: "", model: "", year: "" };
  }
}

function saveCar() {
  try {
    localStorage.setItem("obd-car", JSON.stringify(state.car));
  } catch (error) {
    // хранилище может быть недоступно — игнорируем
  }
}

function applyCarToForm() {
  if (state.car.make && !CAR_MAKES.includes(state.car.make)) {
    CAR_MAKES.push(state.car.make);
  }
  fillMakeOptions();
  elements.make.value = state.car.make;
  fillModelOptions(state.car.make);
  elements.model.value = state.car.model;
  elements.year.value = state.car.year;
}

// Список популярных марок для выпадающего списка
const CAR_MAKES = [
  "Audi", "BMW", "Chery", "Chevrolet", "Citroen", "Daewoo", "Dodge",
  "Fiat", "Ford", "Geely", "GMC", "Haval", "Honda", "Hyundai", "Infiniti",
  "Jaguar", "Jeep", "Kia", "Lada", "Land Rover", "Mazda", "Mercedes-Benz",
  "Mitsubishi", "Nissan", "Peugeot", "Renault", "SEAT", "Skoda", "Subaru",
  "Suzuki", "Tesla", "Toyota", "Volkswagen", "Volvo",
];

// Популярные модели по маркам (подсказки, можно ввести свою)
const CAR_MODELS = {
  Toyota: ["Camry", "Corolla", "RAV4", "Land Cruiser", "Voxy", "Noah", "Prius", "Hilux", "Avensis"],
  Nissan: ["Almera", "Qashqai", "X-Trail", "Note", "Juke", "Tiida", "Pathfinder", "Murano", "Teana"],
  Honda: ["Civic", "Accord", "CR-V", "Fit", "Jazz", "HR-V"],
  Mazda: ["3", "6", "CX-5", "CX-7", "MX-5"],
  Subaru: ["Forester", "Impreza", "Outback", "Legacy", "XV"],
  Mitsubishi: ["Lancer", "Outlander", "Pajero", "ASX", "Galant"],
  Suzuki: ["Vitara", "SX4", "Jimny", "Grand Vitara"],
  Hyundai: ["Solaris", "Creta", "Tucson", "Santa Fe", "Elantra", "i30"],
  Kia: ["Rio", "Sportage", "Ceed", "Sorento", "Soul", "Cerato"],
  Volkswagen: ["Polo", "Golf", "Passat", "Tiguan", "Touareg", "Jetta"],
  Skoda: ["Octavia", "Fabia", "Superb", "Kodiaq", "Rapid"],
  BMW: ["3 Series", "5 Series", "7 Series", "X3", "X5", "X1"],
  "Mercedes-Benz": ["C-Class", "E-Class", "S-Class", "GLC", "GLE", "Sprinter"],
  Audi: ["A3", "A4", "A6", "Q5", "Q7", "A5"],
  Renault: ["Logan", "Duster", "Sandero", "Megane", "Arkana"],
  Lada: ["Granta", "Vesta", "Niva", "Kalina", "Largus", "Priora"],
  Ford: ["Focus", "Mondeo", "Kuga", "Fiesta", "Transit", "Explorer"],
  Chevrolet: ["Cruze", "Aveo", "Lacetti", "Captiva", "Niva"],
  Peugeot: ["308", "408", "3008", "508", "Partner"],
  Citroen: ["C4", "C5", "Berlingo", "C3"],
  Volvo: ["XC60", "XC90", "S60", "V60"],
  Tesla: ["Model 3", "Model S", "Model X", "Model Y"],
  Chery: ["Tiggo 4", "Tiggo 7", "Tiggo 8", "Arrizo"],
  Geely: ["Coolray", "Atlas", "Tugella", "Monjaro"],
  Haval: ["Jolion", "F7", "Dargo", "H9"],
};

function fillMakeOptions() {
  elements.make.textContent = "";

  const empty = document.createElement("option");
  empty.value = "";
  empty.textContent = "Марка";
  elements.make.appendChild(empty);

  CAR_MAKES.forEach((make) => {
    const option = document.createElement("option");
    option.value = make;
    option.textContent = make;
    elements.make.appendChild(option);
  });
}

function fillModelOptions(make) {
  elements.model.textContent = "";

  const empty = document.createElement("option");
  empty.value = "";
  empty.textContent = make ? "Модель" : "Сначала марка";
  elements.model.appendChild(empty);

  (CAR_MODELS[make] || []).forEach((model) => {
    const option = document.createElement("option");
    option.value = model;
    option.textContent = model;
    elements.model.appendChild(option);
  });
}

function renderSymptomChoices() {
  elements.symptomList.textContent = "";

  SYMPTOM_CHOICES.forEach((label) => {
    const wrapper = document.createElement("label");
    wrapper.className = "symptom-option";

    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.value = label;

    const text = document.createElement("span");
    text.textContent = label;

    wrapper.append(checkbox, text);
    elements.symptomList.appendChild(wrapper);
  });
}

function formatNumber(value) {
  if (typeof value !== "number") {
    return String(value);
  }
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

function valueClass(key, value, live) {
  if (value === null || value === undefined) {
    return "";
  }

  if (key === "coolant" && value > 105) {
    return "danger";
  }

  if (key === "voltage") {
    const running = (live.rpm || 0) > 500;
    if (running && value < 13.0) return "warn";
    if (!running && value < 11.8) return "warn";
  }

  if ((key === "fuel_trim_short" || key === "fuel_trim_long") && Math.abs(value) > 10) {
    return "warn";
  }

  return "";
}

function renderTiles(live) {
  elements.tiles.textContent = "";

  TILES.forEach((tile) => {
    const value = live[tile.key];

    const card = document.createElement("div");
    card.className = ("tile " + valueClass(tile.key, value, live)).trim();

    const label = document.createElement("div");
    label.className = "label";
    label.textContent = tile.label;

    const valueLine = document.createElement("div");
    valueLine.className = "value";
    valueLine.textContent = value === null || value === undefined ? "—" : formatNumber(value);

    const unit = document.createElement("span");
    unit.className = "unit";
    unit.textContent = tile.unit;
    valueLine.appendChild(unit);

    card.append(label, valueLine);
    elements.tiles.appendChild(card);
  });
}

function severityClass(severity) {
  if (severity === "СТОП") return "stop";
  if (severity === "СКОРО В СЕРВИС") return "soon";
  return "watch";
}

function renderHints(hints) {
  elements.hints.textContent = "";

  if (!hints.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "Проблем не найдено.";
    elements.hints.appendChild(empty);
    return;
  }

  hints.forEach((hint) => {
    const card = document.createElement("div");
    card.className = "hint " + severityClass(hint.severity);

    const head = document.createElement("div");
    head.className = "head";

    const pill = document.createElement("span");
    pill.className = "pill";
    pill.textContent = hint.severity;

    const title = document.createElement("span");
    title.className = "title";
    title.textContent = hint.title;

    head.append(pill, title);

    const list = document.createElement("ol");
    hint.actions.forEach((action) => {
      const item = document.createElement("li");
      item.textContent = action;
      list.appendChild(item);
    });

    card.append(head, list);
    elements.hints.appendChild(card);
  });
}

function renderStatus(data) {
  state.source = data.source;

  elements.badge.textContent = data.source === "demo" ? "Демо" : "Адаптер";
  elements.badge.classList.toggle("demo", data.source === "demo");
  elements.badge.classList.toggle("real", data.source === "real");

  renderHealth(data.health);
  renderDetected(data.vehicle_info);

  if (data.connected) {
    elements.status.textContent = "Подключено";
  } else {
    elements.status.textContent = data.error || "Нет связи";
  }

  document.querySelectorAll(".demo-only").forEach((element) => {
    element.classList.toggle("hidden", data.source !== "demo");
  });

  if (data.source === "demo" && data.scenario) {
    elements.scenario.value = data.scenario;
  }
}

function renderDetected(info) {
  if (!elements.detectedInfo) {
    return;
  }

  if (!info || (!info.make && !info.protocol)) {
    elements.detectedInfo.classList.add("hidden");
    return;
  }

  const parts = [];
  if (info.make) {
    parts.push("Марка: " + info.make);
  }
  if (info.vin) {
    parts.push("VIN: " + info.vin);
  }
  if (info.protocol) {
    parts.push("Протокол: " + info.protocol);
  }

  elements.detectedInfo.textContent = "Определено адаптером — " + parts.join(" · ");
  elements.detectedInfo.classList.remove("hidden");

  // Если марка определилась — подставляем её в список, чтобы ИИ давал точные советы
  if (info.make && !state.car.make) {
    state.car.make = info.make;
    if (!CAR_MAKES.includes(info.make)) {
      CAR_MAKES.push(info.make);
      fillMakeOptions();
    }
    elements.make.value = info.make;
    fillModelOptions(info.make);
    saveCar();
  }
}

function renderHealth(health) {
  if (!health || health.score === null || health.score === undefined) {
    elements.health.textContent = "Состояние: —";
    elements.health.className = "health";
    return;
  }

  elements.health.textContent = "Состояние: " + health.score + "/100 · " + health.label;

  if (health.score >= 90) {
    elements.health.className = "health good";
  } else if (health.score >= 70) {
    elements.health.className = "health ok";
  } else if (health.score >= 50) {
    elements.health.className = "health warn";
  } else {
    elements.health.className = "health bad";
  }
}

function renderAlert(data) {
  if (data.stopped) {
    elements.alert.textContent = "Остановитесь: обнаружена причина со статусом СТОП.";
    elements.alert.classList.remove("hidden");
  } else {
    elements.alert.classList.add("hidden");
  }
}

function pushHistory(live) {
  ["rpm", "coolant"].forEach((key) => {
    const value = live[key];
    if (typeof value === "number") {
      state.history[key].push(value);
      if (state.history[key].length > MAX_POINTS) {
        state.history[key].shift();
      }
    }
  });
}

function drawChart(canvas, values, color) {
  const context = canvas.getContext("2d");
  const ratio = window.devicePixelRatio || 1;
  const width = canvas.clientWidth;
  const height = canvas.clientHeight;

  if (!width || !height) {
    return;
  }

  canvas.width = width * ratio;
  canvas.height = height * ratio;
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  context.clearRect(0, 0, width, height);

  if (values.length < 2) {
    return;
  }

  const min = Math.min(...values);
  const max = Math.max(...values);
  const range = max - min || 1;
  const padding = 10;

  context.beginPath();
  values.forEach((value, index) => {
    const x = padding + ((width - padding * 2) * index) / (values.length - 1);
    const y = height - padding - ((height - padding * 2) * (value - min)) / range;
    if (index === 0) {
      context.moveTo(x, y);
    } else {
      context.lineTo(x, y);
    }
  });

  context.strokeStyle = color;
  context.lineWidth = 2;
  context.lineJoin = "round";
  context.stroke();
}

function drawCharts() {
  drawChart(elements.rpmChart, state.history.rpm, "#35c28f");
  drawChart(elements.coolantChart, state.history.coolant, "#5b9dff");
}

function render(data) {
  renderStatus(data);
  renderAlert(data);
  renderTiles(data.live || {});
  renderHints(data.hints || []);
  pushHistory(data.live || {});
  drawCharts();
  elements.updated.textContent = data.updated_at ? "Обновлено: " + data.updated_at : "";
  maybeAutoAdvice(data);
}

async function fetchLive() {
  try {
    const response = await fetch("/api/live", { cache: "no-store" });
    const data = await response.json();
    render(data);
  } catch (error) {
    elements.status.textContent = "Сервер недоступен: " + error.message;
  }
}

function setAutoRefresh(enabled) {
  if (state.timer) {
    clearInterval(state.timer);
    state.timer = null;
  }
  if (enabled) {
    state.timer = setInterval(fetchLive, REFRESH_MS);
  }
}

function renderAdvice(data) {
  if (data.error) {
    elements.adviceText.textContent = "Не удалось получить рекомендацию: " + data.error;
    state.advice.lastText = "";
    elements.partBox.classList.add("hidden");
  } else {
    const text = data.advice || "Пустой ответ нейросети.";
    elements.adviceText.textContent = text;
    state.advice.lastText = text;
    renderPart(data.part, data.cost, data.links);
  }
  elements.adviceStatus.textContent = "";
  state.advice.loading = false;
}

function speak(text) {
  if (!text) {
    elements.voiceStatus.textContent = "Сначала получите ответ.";
    return;
  }
  if (!("speechSynthesis" in window)) {
    elements.voiceStatus.textContent = "Браузер не поддерживает озвучку.";
    return;
  }
  window.speechSynthesis.cancel();
  const utterance = new SpeechSynthesisUtterance(text);
  utterance.lang = "ru-RU";
  utterance.rate = 1.0;
  window.speechSynthesis.speak(utterance);
}

function startVoiceInput() {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) {
    elements.voiceStatus.textContent = "Браузер не поддерживает распознавание голоса.";
    return;
  }

  const recognition = new Recognition();
  recognition.lang = "ru-RU";
  recognition.interimResults = false;
  recognition.maxAlternatives = 1;

  elements.voiceStatus.textContent = "Слушаю…";

  recognition.onresult = (event) => {
    const text = event.results[0][0].transcript;
    elements.symptoms.value = text;
    elements.voiceStatus.textContent = "";
    fetchAdvice();
  };

  recognition.onerror = (event) => {
    elements.voiceStatus.textContent = "Не расслышал: " + event.error;
  };

  recognition.onend = () => {
    if (elements.voiceStatus.textContent === "Слушаю…") {
      elements.voiceStatus.textContent = "";
    }
  };

  recognition.start();
}

function renderPart(part, cost, links) {
  if (!part) {
    elements.partBox.classList.add("hidden");
    return;
  }

  elements.partName.textContent = part;

  if (cost) {
    elements.partCost.textContent = "Примерная стоимость ремонта: " + cost;
    elements.partCost.classList.remove("hidden");
  } else {
    elements.partCost.textContent = "";
    elements.partCost.classList.add("hidden");
  }

  elements.partLinks.textContent = "";

  (links || []).forEach((entry) => {
    const anchor = document.createElement("a");
    anchor.href = entry.url;
    anchor.target = "_blank";
    anchor.rel = "noopener";
    anchor.textContent = entry.label;
    elements.partLinks.appendChild(anchor);
  });

  elements.partBox.classList.remove("hidden");
}

async function fetchAdvice() {
  if (state.advice.loading) {
    return;
  }
  state.advice.loading = true;
  elements.adviceStatus.textContent = "Думаю…";
  elements.adviceBtn.disabled = true;

  try {
    const response = await fetch("/api/advice", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      cache: "no-store",
      body: JSON.stringify({
        make: state.car.make,
        model: state.car.model,
        year: state.car.year,
        symptoms: elements.symptoms.value.trim(),
      }),
    });
    const data = await response.json();
    renderAdvice(data);
  } catch (error) {
    renderAdvice({ error: "Сервер недоступен: " + error.message });
  } finally {
    elements.adviceBtn.disabled = false;
  }
}

// Автоматически спрашиваем ИИ, когда появляется новая ошибка
function maybeAutoAdvice(data) {
  if (!data.connected) {
    state.advice.lastCodesKey = "";
    return;
  }

  const codes = data.codes || [];
  const key = [...codes].sort().join(",");

  if (key && key !== state.advice.lastCodesKey) {
    state.advice.lastCodesKey = key;
    fetchAdvice();
  } else if (!key) {
    state.advice.lastCodesKey = "";
  }
}

function renderSymptomResult(data) {
  if (data.error) {
    elements.symptomResult.classList.remove("hidden");
    elements.symptomResult.textContent = "Не удалось определить причину: " + data.error;
    return;
  }

  elements.symptomResult.textContent = "";

  const diagnosis = document.createElement("p");
  diagnosis.className = "symptom-diagnosis";
  diagnosis.textContent = data.diagnosis || "Пустой ответ нейросети.";
  elements.symptomResult.appendChild(diagnosis);

  (data.parts || []).forEach((part) => {
    const card = document.createElement("div");
    card.className = "symptom-part";

    const title = document.createElement("div");
    title.className = "part-title";
    title.textContent = part.name;
    card.appendChild(title);

    const links = document.createElement("div");
    links.className = "part-links";
    (part.links || []).forEach((entry) => {
      const anchor = document.createElement("a");
      anchor.href = entry.url;
      anchor.target = "_blank";
      anchor.rel = "noopener";
      anchor.textContent = entry.label;
      links.appendChild(anchor);
    });
    card.appendChild(links);

    elements.symptomResult.appendChild(card);
  });

  elements.symptomResult.classList.remove("hidden");
}

async function fetchSymptoms() {
  const selected = Array.from(
    elements.symptomList.querySelectorAll("input[type=checkbox]:checked")
  ).map((checkbox) => checkbox.value);

  if (!selected.length) {
    elements.symptomStatus.textContent = "Отметьте хотя бы один симптом.";
    return;
  }

  elements.symptomStatus.textContent = "Анализирую…";
  elements.symptomBtn.disabled = true;
  elements.symptomResult.classList.add("hidden");

  try {
    const response = await fetch("/api/symptoms", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        make: state.car.make,
        model: state.car.model,
        year: state.car.year,
        symptoms: selected,
      }),
    });
    const data = await response.json();
    renderSymptomResult(data);
    elements.symptomStatus.textContent = data.error ? "" : "Готово.";
  } catch (error) {
    renderSymptomResult({ error: "Сервер недоступен: " + error.message });
    elements.symptomStatus.textContent = "";
  } finally {
    elements.symptomBtn.disabled = false;
  }
}

function loadTgChatId() {
  try {
    return localStorage.getItem("obd-tg-chat-id") || "";
  } catch (error) {
    return "";
  }
}

function saveTgChatId(chatId) {
  try {
    localStorage.setItem("obd-tg-chat-id", chatId);
  } catch (error) {
    // хранилище может быть недоступно — игнорируем
  }
}

async function tgConnect(silent) {
  const chatId = elements.tgChatId.value.trim();
  if (!chatId) {
    elements.tgStatus.textContent = "Введите chat_id или нажмите «Автоопределить».";
    return;
  }

  elements.tgStatus.textContent = silent ? "Подключаю…" : "Отправляю тестовое сообщение…";
  elements.tgBtn.disabled = true;

  try {
    const response = await fetch("/api/telegram", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, silent: silent }),
    });
    const data = await response.json();

    if (data.error) {
      elements.tgStatus.textContent = data.error;
    } else {
      saveTgChatId(chatId);
      elements.tgStatus.textContent = silent
        ? "Подключено."
        : "Готово: проверьте сообщение в Telegram.";
    }
  } catch (error) {
    elements.tgStatus.textContent = "Сервер недоступен: " + error.message;
  } finally {
    elements.tgBtn.disabled = false;
  }
}

async function tgLookup() {
  elements.tgStatus.textContent = "Ищу chat_id…";
  elements.tgLookupBtn.disabled = true;

  try {
    const response = await fetch("/api/telegram/lookup");
    const data = await response.json();

    if (data.error) {
      elements.tgStatus.textContent = data.error;
    } else {
      elements.tgChatId.value = data.chat_id;
      saveTgChatId(data.chat_id);
      elements.tgStatus.textContent = "Нашёл chat_id. Теперь нажмите «Подключить».";
    }
  } catch (error) {
    elements.tgStatus.textContent = "Сервер недоступен: " + error.message;
  } finally {
    elements.tgLookupBtn.disabled = false;
  }
}

elements.refreshBtn.addEventListener("click", fetchLive);

elements.adviceBtn.addEventListener("click", fetchAdvice);

elements.voiceBtn.addEventListener("click", startVoiceInput);

elements.speakBtn.addEventListener("click", () => speak(state.advice.lastText));

elements.symptomBtn.addEventListener("click", fetchSymptoms);

async function fetchDtc() {
  elements.dtcStatus.textContent = "Читаю блоки…";
  elements.dtcBtn.disabled = true;
  elements.dtcBlocks.textContent = "";

  try {
    const response = await fetch("/api/dtc/read", { cache: "no-store" });
    const data = await response.json();
    renderDtcBlocks(data);
    elements.dtcStatus.textContent = data.error ? "" : "Готово.";
  } catch (error) {
    renderDtcBlocks({ error: "Сервер недоступен: " + error.message });
    elements.dtcStatus.textContent = "";
  } finally {
    elements.dtcBtn.disabled = false;
  }
}

function renderDtcBlocks(data) {
  elements.dtcBlocks.textContent = "";

  if (data.error) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "Не удалось прочитать ошибки: " + data.error;
    elements.dtcBlocks.appendChild(empty);
    return;
  }

  const blocks = data.blocks || {};
  const names = Object.keys(blocks);

  if (!names.length) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = "Ошибок не найдено ни в одном блоке.";
    elements.dtcBlocks.appendChild(empty);
    return;
  }

  names.forEach((blockName) => {
    const card = document.createElement("div");
    card.className = "dtc-block";

    const title = document.createElement("div");
    title.className = "dtc-block-title";
    title.textContent = blockName;
    card.appendChild(title);

    const list = document.createElement("div");
    list.className = "dtc-codes";
    (blocks[blockName] || []).forEach((code) => {
      const pill = document.createElement("span");
      pill.className = "dtc-code";
      pill.textContent = code;
      list.appendChild(pill);
    });
    card.appendChild(list);

    elements.dtcBlocks.appendChild(card);
  });
}

elements.dtcBtn.addEventListener("click", fetchDtc);

// ---------- Стирание ошибок ----------
elements.dtcClearBtn.addEventListener("click", async () => {
  const confirmed = confirm(
    "Стереть коды ошибок из блоков управления?\n\n" +
      "После стирания погаснет лампа Check Engine. Если неисправность не устранена, " +
      "ошибка появится снова. Также сбросится готовность к техосмотру."
  );
  if (!confirmed) {
    return;
  }

  elements.dtcStatus.textContent = "Стираю…";
  elements.dtcClearBtn.disabled = true;

  try {
    const response = await fetch("/api/dtc/clear", { method: "POST" });
    const data = await response.json();

    if (data.error) {
      elements.dtcStatus.textContent = data.error;
    } else {
      elements.dtcStatus.textContent = "Ошибки стёрты.";
      renderDtcBlocks({ blocks: {} });
      fetchLive();
    }
  } catch (error) {
    elements.dtcStatus.textContent = "Сервер недоступен: " + error.message;
  } finally {
    elements.dtcClearBtn.disabled = false;
  }
});

// ---------- Выбор адаптера ----------
async function refreshAdapters() {
  const type = elements.adapterType.value;
  elements.adapterStatus.textContent = "Ищу…";
  elements.adapterList.textContent = "";

  try {
    const response = await fetch("/api/adapters", { cache: "no-store" });
    const data = await response.json();
    const items = data[type] || [];

    if (!items.length) {
      elements.adapterStatus.textContent = "Ничего не найдено. Проверьте, что адаптер включён.";
      return;
    }

    items.forEach((item) => {
      const option = document.createElement("option");
      option.value = item;
      option.textContent = item;
      elements.adapterList.appendChild(option);
    });

    elements.adapterStatus.textContent = "Найдено: " + items.length;
  } catch (error) {
    elements.adapterStatus.textContent = "Сервер недоступен: " + error.message;
  }
}

elements.adapterRefresh.addEventListener("click", refreshAdapters);

elements.adapterType.addEventListener("change", () => {
  if (elements.adapterType.value === "demo") {
    elements.adapterList.textContent = "";
    elements.adapterStatus.textContent = "Демо-режим: адаптер не нужен.";
    return;
  }
  refreshAdapters();
});

elements.adapterConnect.addEventListener("click", async () => {
  const type = elements.adapterType.value;
  const value = elements.adapterList.value || "";

  elements.adapterStatus.textContent = "Подключаю…";
  elements.adapterConnect.disabled = true;

  try {
    const response = await fetch("/api/connect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: type, value: value }),
    });
    const data = await response.json();

    if (data.error) {
      elements.adapterStatus.textContent = data.error;
    } else {
      elements.adapterStatus.textContent = "Подключено: " + data.type;
      fetchLive();
    }
  } catch (error) {
    elements.adapterStatus.textContent = "Сервер недоступен: " + error.message;
  } finally {
    elements.adapterConnect.disabled = false;
  }
});

// ---------- Расширенные параметры ----------
elements.paramsBtn.addEventListener("click", async () => {
  elements.paramsStatus.textContent = "Читаю все датчики…";
  elements.paramsBtn.disabled = true;
  elements.paramsGroups.textContent = "";

  try {
    const [catalogResponse, valuesResponse] = await Promise.all([
      fetch("/api/params/catalog", { cache: "no-store" }),
      fetch("/api/params/extended", { cache: "no-store" }),
    ]);
    const catalog = await catalogResponse.json();
    const values = await valuesResponse.json();

    if (values.error) {
      elements.paramsStatus.textContent = values.error;
      return;
    }

    renderParams(catalog.groups || [], values.values || {});
    elements.paramsStatus.textContent = "Готово.";
  } catch (error) {
    elements.paramsStatus.textContent = "Сервер недоступен: " + error.message;
  } finally {
    elements.paramsBtn.disabled = false;
  }
});

function renderParams(groups, values) {
  elements.paramsGroups.textContent = "";

  groups.forEach((group) => {
    const block = document.createElement("div");
    block.className = "params-group";

    const title = document.createElement("div");
    title.className = "params-group-title";
    title.textContent = group.name;
    block.appendChild(title);

    const grid = document.createElement("div");
    grid.className = "params-grid";

    (group.params || []).forEach((param) => {
      const value = values[param.key];
      if (value === null || value === undefined) {
        return;
      }

      const card = document.createElement("div");
      card.className = "param-card";

      const label = document.createElement("div");
      label.className = "param-label";
      label.textContent = param.name;

      const line = document.createElement("div");
      line.className = "param-value";
      line.textContent = Number.isInteger(value) ? String(value) : value.toFixed(param.digits || 1);

      const unit = document.createElement("span");
      unit.className = "param-unit";
      unit.textContent = param.unit;
      line.appendChild(unit);

      card.append(label, line);
      grid.appendChild(card);
    });

    block.appendChild(grid);
    elements.paramsGroups.appendChild(block);
  });
}

elements.tgLookupBtn.addEventListener("click", tgLookup);

elements.tgBtn.addEventListener("click", () => tgConnect(false));

["make", "model", "year"].forEach((key) => {
  elements[key].addEventListener("change", () => {
    state.car[key] = elements[key].value.trim();
    if (key === "make") {
      fillModelOptions(state.car.make);
      state.car.model = "";
      elements.model.value = "";
    }
    saveCar();
  });
});

async function fetchVin() {
  const vin = elements.vin.value.trim();
  if (!vin) {
    elements.vinStatus.textContent = "Введите VIN.";
    return;
  }

  elements.vinStatus.textContent = "Определяю…";
  elements.vinBtn.disabled = true;

  try {
    const response = await fetch("/api/vin/" + encodeURIComponent(vin));
    const data = await response.json();

    if (data.error) {
      elements.vinStatus.textContent = data.error;
    } else {
      state.car.make = data.vehicle.make || "";
      state.car.model = data.vehicle.model || "";
      state.car.year = data.vehicle.year || "";
      applyCarToForm();
      saveCar();
      elements.vinStatus.textContent = "Автомобиль определён по VIN.";
    }
  } catch (error) {
    elements.vinStatus.textContent = "Сервер недоступен: " + error.message;
  } finally {
    elements.vinBtn.disabled = false;
  }
}

elements.vinBtn.addEventListener("click", fetchVin);

elements.reportBtn.addEventListener("click", async () => {
  try {
    const response = await fetch("/api/report");

    if (!response.ok) {
      const data = await response.json();
      alert(data.error || "Не удалось сформировать отчёт");
      return;
    }

    // Имя файла приходит от сервера в заголовке Content-Disposition
    const disposition = response.headers.get("Content-Disposition") || "";
    const match = disposition.match(/filename="?([^";]+)"?/);
    const filename = match ? match[1] : "obd_report.json";

    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    URL.revokeObjectURL(url);
  } catch (error) {
    alert("Ошибка при скачивании отчёта: " + error.message);
  }
});

elements.autoRefresh.addEventListener("change", () => {
  setAutoRefresh(elements.autoRefresh.checked);
});

elements.scenario.addEventListener("change", async () => {
  await fetch("/api/demo/" + elements.scenario.value, { method: "POST" });
  state.history.rpm = [];
  state.history.coolant = [];
  fetchLive();
});

// Не опрашиваем сервер, пока вкладка скрыта
document.addEventListener("visibilitychange", () => {
  if (document.hidden) {
    setAutoRefresh(false);
  } else if (elements.autoRefresh.checked) {
    setAutoRefresh(true);
    fetchLive();
  }
});

state.car = loadCar();
applyCarToForm();
renderSymptomChoices();

// Если Telegram уже настраивали — тихо подключаемся заново
const savedTgChatId = loadTgChatId();
if (savedTgChatId) {
  elements.tgChatId.value = savedTgChatId;
  tgConnect(true);
}

fetchLive();
setAutoRefresh(true);
