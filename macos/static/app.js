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

// Цвета линий графиков (по кругу)
const CHART_COLORS = [
  "#35c28f", "#5b9dff", "#f5a524", "#e5484d",
  "#a78bfa", "#22d3ee", "#f472b6", "#84cc16",
];

const state = {
  timer: null,
  source: "demo",
  chartKeys: [],      // параметры, для которых строятся графики
  chartData: {},      // key -> история значений
  catalogGroups: [],  // каталог параметров с сервера
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
  chartSelect: document.getElementById("chart-select"),
  chartAdd: document.getElementById("chart-add"),
  chartClear: document.getElementById("chart-clear"),
  chartsContainer: document.getElementById("charts-container"),
  chartsEmpty: document.getElementById("charts-empty"),
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

// ---------- Графики: только выбранные пользователем параметры ----------

// Сколько точек храним в истории (при обновлении раз в 2.5 с — около 5 минут)
const CHART_MAX_POINTS = 120;

function loadChartKeys() {
  try {
    const saved = JSON.parse(localStorage.getItem("obd-charts") || "[]");
    return Array.isArray(saved) ? saved.filter((key) => typeof key === "string") : [];
  } catch (error) {
    return [];
  }
}

function saveChartKeys() {
  try {
    localStorage.setItem("obd-charts", JSON.stringify(state.chartKeys));
  } catch (error) {
    // хранилище может быть недоступно — игнорируем
  }
}

// Заполняет выпадающий список параметрами, сгруппированными по системам
async function loadChartCatalog() {
  try {
    const response = await fetch("/api/params/catalog", { cache: "no-store" });
    const data = await response.json();
    elements.chartSelect.textContent = "";

    (data.groups || []).forEach((group) => {
      const optgroup = document.createElement("optgroup");
      optgroup.label = group.name;

      (group.params || []).forEach((param) => {
        if (state.chartKeys.includes(param.key)) {
          return; // уже добавлен
        }
        const option = document.createElement("option");
        option.value = param.key;
        option.textContent = param.name + " (" + param.unit + ")";
        optgroup.appendChild(option);
      });

      if (optgroup.children.length) {
        elements.chartSelect.appendChild(optgroup);
      }
    });
  } catch (error) {
    elements.chartsEmpty.textContent = "Не удалось загрузить список параметров: " + error.message;
  }
}

function chartInfo(key) {
  for (const group of state.catalogGroups) {
    for (const param of group.params || []) {
      if (param.key === key) {
        return param;
      }
    }
  }
  return { key: key, name: key, unit: "", digits: 1 };
}

function addChart() {
  const key = elements.chartSelect.value;
  if (!key || state.chartKeys.includes(key)) {
    return;
  }
  state.chartKeys.push(key);
  state.chartData[key] = [];
  saveChartKeys();
  renderCharts();
  loadChartCatalog();
  fetchChartValues();
}

function removeChart(key) {
  state.chartKeys = state.chartKeys.filter((item) => item !== key);
  delete state.chartData[key];
  saveChartKeys();
  renderCharts();
  loadChartCatalog();
}

function renderCharts() {
  elements.chartsContainer.textContent = "";

  if (!state.chartKeys.length) {
    elements.chartsEmpty.classList.remove("hidden");
    return;
  }
  elements.chartsEmpty.classList.add("hidden");

  state.chartKeys.forEach((key, index) => {
    const info = chartInfo(key);

    const figure = document.createElement("figure");
    figure.className = "chart-figure";

    const header = document.createElement("div");
    header.className = "chart-header";

    const caption = document.createElement("span");
    caption.className = "chart-caption";
    caption.textContent = info.name + ", " + info.unit;

    const valueSpan = document.createElement("span");
    valueSpan.className = "chart-value";
    valueSpan.id = "chart-value-" + index;

    const expandBtn = document.createElement("button");
    expandBtn.className = "chart-remove";
    expandBtn.type = "button";
    expandBtn.textContent = "⤢";
    expandBtn.title = "Развернуть график";
    expandBtn.addEventListener("click", () => openChartModal(key));

    const removeBtn = document.createElement("button");
    removeBtn.className = "chart-remove";
    removeBtn.type = "button";
    removeBtn.textContent = "✕";
    removeBtn.title = "Убрать график";
    removeBtn.addEventListener("click", () => removeChart(key));

    header.append(caption, valueSpan, expandBtn, removeBtn);

    const canvas = document.createElement("canvas");
    canvas.className = "chart-canvas";
    canvas.height = 170;
    canvas.dataset.key = key;

    figure.append(header, canvas);
    elements.chartsContainer.appendChild(figure);
  });

  drawAllCharts();
}

function drawAllCharts() {
  state.chartKeys.forEach((key, index) => {
    const canvas = elements.chartsContainer.querySelector(
      'canvas[data-key="' + key + '"]'
    );
    if (!canvas) {
      return;
    }

    const points = state.chartData[key] || [];
    drawChart(canvas, points, CHART_COLORS[index % CHART_COLORS.length]);

    const info = chartInfo(key);
    const valueSpan = document.getElementById("chart-value-" + index);
    if (valueSpan) {
      const last = points.length ? points[points.length - 1].v : null;
      valueSpan.textContent = last === null ? "—" : formatChartValue(last, info);
    }
  });
}

function formatChartValue(value, info) {
  const digits = info.digits === undefined ? 1 : info.digits;
  const text = digits === 0 ? String(Math.round(value)) : value.toFixed(digits);
  return text + " " + (info.unit || "");
}

// Время в формате ЧЧ:ММ:СС
function formatClock(timestamp) {
  const date = new Date(timestamp);
  const pad = (number) => String(number).padStart(2, "0");
  return pad(date.getHours()) + ":" + pad(date.getMinutes()) + ":" + pad(date.getSeconds());
}

/**
 * Рисует график с осями координат.
 * points — массив {t: время (мс), v: значение}.
 */
function drawChart(canvas, points, color) {
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

  // Отступы под подписи осей
  const padLeft = 52;
  const padRight = 12;
  const padTop = 12;
  const padBottom = 26;

  const plotWidth = width - padLeft - padRight;
  const plotHeight = height - padTop - padBottom;

  if (plotWidth <= 0 || plotHeight <= 0) {
    return;
  }

  // Оси
  context.strokeStyle = "#2b3a47";
  context.lineWidth = 1;
  context.beginPath();
  context.moveTo(padLeft, padTop);
  context.lineTo(padLeft, padTop + plotHeight);
  context.lineTo(padLeft + plotWidth, padTop + plotHeight);
  context.stroke();

  if (points.length < 2) {
    context.fillStyle = "#92a5b7";
    context.font = "12px -apple-system, sans-serif";
    context.fillText("Ждём данные…", padLeft + 8, padTop + plotHeight / 2);
    return;
  }

  // Диапазон значений (Y) и времени (X)
  const values = points.map((point) => point.v);
  let min = Math.min(...values);
  let max = Math.max(...values);

  if (min === max) {
    // Плоская линия: добавляем запас, чтобы она была по центру
    min = min - 1;
    max = max + 1;
  }
  const span = max - min;

  const timeStart = points[0].t;
  const timeEnd = points[points.length - 1].t;
  const timeSpan = Math.max(timeEnd - timeStart, 1);

  // Горизонтальные линии сетки с подписями значений
  const gridLines = 4;
  context.font = "11px -apple-system, sans-serif";
  context.textAlign = "right";
  context.textBaseline = "middle";

  // Точность подписи зависит от разброса значений
  const axisDigits = span >= 100 ? 0 : span >= 10 ? 1 : span >= 1 ? 2 : span >= 0.1 ? 3 : 4;

  for (let i = 0; i <= gridLines; i++) {
    const fraction = i / gridLines;
    const y = padTop + plotHeight * fraction;
    const value = max - span * fraction;

    context.strokeStyle = i === gridLines ? "#2b3a47" : "#1f2a35";
    context.beginPath();
    context.moveTo(padLeft, y);
    context.lineTo(padLeft + plotWidth, y);
    context.stroke();

    context.fillStyle = "#92a5b7";
    context.fillText(value.toFixed(axisDigits), padLeft - 8, y);
  }

  // Вертикальные линии сетки с подписями времени.
  // На узких графиках меньше подписей, чтобы они не наезжали друг на друга.
  const timeLines = plotWidth < 420 ? 2 : 4;
  context.textAlign = "center";
  context.textBaseline = "top";

  for (let i = 0; i <= timeLines; i++) {
    const fraction = i / timeLines;
    const x = padLeft + plotWidth * fraction;
    const time = timeStart + timeSpan * fraction;

    if (i > 0 && i < timeLines) {
      context.strokeStyle = "#1f2a35";
      context.beginPath();
      context.moveTo(x, padTop);
      context.lineTo(x, padTop + plotHeight);
      context.stroke();
    }

    context.fillStyle = "#92a5b7";
    // Крайние подписи прижимаем, чтобы не вылезали за границы
    if (i === 0) {
      context.textAlign = "left";
    } else if (i === timeLines) {
      context.textAlign = "right";
    } else {
      context.textAlign = "center";
    }
    context.fillText(formatClock(time), x, padTop + plotHeight + 6);
  }

  // Сама линия графика
  context.beginPath();
  points.forEach((point, index) => {
    const x = padLeft + (plotWidth * (point.t - timeStart)) / timeSpan;
    const y = padTop + plotHeight - (plotHeight * (point.v - min)) / span;
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

  // Точка на последнем значении
  const lastPoint = points[points.length - 1];
  const lastX = padLeft + (plotWidth * (lastPoint.t - timeStart)) / timeSpan;
  const lastY = padTop + plotHeight - (plotHeight * (lastPoint.v - min)) / span;

  context.beginPath();
  context.arc(lastX, lastY, 3.5, 0, Math.PI * 2);
  context.fillStyle = color;
  context.fill();
}

// ---------- Развёрнутый график (для точного просмотра) ----------

let modalState = { key: "", zoom: CHART_MAX_POINTS };

function openChartModal(key) {
  modalState = { key: key, zoom: CHART_MAX_POINTS };

  const overlay = document.createElement("div");
  overlay.className = "chart-modal";
  overlay.id = "chart-modal";

  const box = document.createElement("div");
  box.className = "chart-modal-box";

  const header = document.createElement("div");
  header.className = "chart-modal-header";

  const info = chartInfo(key);
  const title = document.createElement("span");
  title.className = "chart-modal-title";
  title.textContent = info.name + ", " + info.unit;

  const current = document.createElement("span");
  current.className = "chart-value";
  current.id = "modal-value";

  const zoomOutBtn = document.createElement("button");
  zoomOutBtn.className = "chart-remove";
  zoomOutBtn.type = "button";
  zoomOutBtn.textContent = "−";
  zoomOutBtn.title = "Показать меньше точек (крупнее)";
  zoomOutBtn.addEventListener("click", () => changeZoom(-10));

  const zoomInBtn = document.createElement("button");
  zoomInBtn.className = "chart-remove";
  zoomInBtn.type = "button";
  zoomInBtn.textContent = "+";
  zoomInBtn.title = "Показать больше точек";
  zoomInBtn.addEventListener("click", () => changeZoom(10));

  const resetBtn = document.createElement("button");
  resetBtn.className = "chart-remove";
  resetBtn.type = "button";
  resetBtn.textContent = "Вся история";
  resetBtn.addEventListener("click", () => {
    modalState.zoom = CHART_MAX_POINTS;
    drawModalChart();
  });

  const closeBtn = document.createElement("button");
  closeBtn.className = "chart-remove";
  closeBtn.type = "button";
  closeBtn.textContent = "Закрыть";
  closeBtn.addEventListener("click", closeChartModal);

  header.append(title, current, zoomOutBtn, zoomInBtn, resetBtn, closeBtn);

  const canvas = document.createElement("canvas");
  canvas.className = "chart-modal-canvas";
  canvas.id = "modal-chart";

  const hint = document.createElement("p");
  hint.className = "advice-subtitle";
  hint.textContent =
    "Кнопки − и + меняют масштаб. По оси X — время, по оси Y — значение параметра.";

  box.append(header, canvas, hint);
  overlay.appendChild(box);
  overlay.addEventListener("click", (event) => {
    if (event.target === overlay) {
      closeChartModal();
    }
  });

  document.body.appendChild(overlay);
  drawModalChart();
}

function closeChartModal() {
  const overlay = document.getElementById("chart-modal");
  if (overlay) {
    overlay.remove();
  }
}

function changeZoom(delta) {
  // Ограничиваем: от 10 точек до всей истории
  modalState.zoom = Math.max(10, Math.min(CHART_MAX_POINTS, modalState.zoom + delta));
  drawModalChart();
}

function drawModalChart() {
  const canvas = document.getElementById("modal-chart");
  if (!canvas) {
    return;
  }

  const all = state.chartData[modalState.key] || [];
  const points = all.slice(Math.max(0, all.length - modalState.zoom));

  const index = state.chartKeys.indexOf(modalState.key);
  const color = CHART_COLORS[(index < 0 ? 0 : index) % CHART_COLORS.length];

  drawChart(canvas, points, color);

  const info = chartInfo(modalState.key);
  const valueSpan = document.getElementById("modal-value");
  if (valueSpan) {
    const last = points.length ? points[points.length - 1].v : null;
    valueSpan.textContent = last === null ? "—" : formatChartValue(last, info);
  }
}

// Запрашивает значения только выбранных параметров и добавляет их в историю
async function fetchChartValues() {
  if (!state.chartKeys.length) {
    return;
  }

  try {
    const response = await fetch("/api/params/values", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ keys: state.chartKeys }),
    });
    const data = await response.json();
    if (data.error) {
      return;
    }

    const now = Date.now();
    Object.keys(data.values || {}).forEach((key) => {
      const value = data.values[key];
      if (typeof value !== "number") {
        return;
      }
      if (!state.chartData[key]) {
        state.chartData[key] = [];
      }
      state.chartData[key].push({ t: now, v: value });
      if (state.chartData[key].length > CHART_MAX_POINTS) {
        state.chartData[key].shift();
      }
    });

    drawAllCharts();
    if (document.getElementById("chart-modal")) {
      drawModalChart();
    }
  } catch (error) {
    // молча пропускаем: график обновится при следующем цикле
  }
}

function render(data) {
  renderStatus(data);
  renderAlert(data);
  renderTiles(data.live || {});
  renderHints(data.hints || []);
  drawAllCharts();
  elements.updated.textContent = data.updated_at ? "Обновлено: " + data.updated_at : "";
  maybeAutoAdvice(data);
  fetchChartValues();
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

// ---------- Кнопки графиков ----------
elements.chartAdd.addEventListener("click", addChart);

elements.chartClear.addEventListener("click", () => {
  state.chartKeys = [];
  state.chartData = {};
  saveChartKeys();
  renderCharts();
  loadChartCatalog();
});

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
  // При смене сценария начинаем историю графиков заново
  state.chartKeys.forEach((key) => {
    state.chartData[key] = [];
  });
  renderCharts();
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

// Графики: восстанавливаем выбранные параметры
state.chartKeys = loadChartKeys();
state.chartKeys.forEach((key) => {
  state.chartData[key] = [];
});

// Каталог параметров нужен и для списка выбора, и для подписей графиков
fetch("/api/params/catalog", { cache: "no-store" })
  .then((response) => response.json())
  .then((data) => {
    state.catalogGroups = data.groups || [];
    renderCharts();
    loadChartCatalog();
  })
  .catch(() => {
    renderCharts();
  });

// Если Telegram уже настраивали — тихо подключаемся заново
const savedTgChatId = loadTgChatId();
if (savedTgChatId) {
  elements.tgChatId.value = savedTgChatId;
  tgConnect(true);
}

fetchLive();
setAutoRefresh(true);
