// Презентация ВКР — Сульдин А.В. (ЮГУ). PptxGenJS.
const pptxgen = require("pptxgenjs");
const fs = require("fs");

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE";            // 13.33 x 7.5
pres.author = "Сульдин А.В.";
pres.title = "ВКР — система контроля доступа по траектории BLE";

const PW = 13.33, PH = 7.5, MX = 0.7;
// Палитра «сигнал»
const NAVY = "0E2A47", NAVY2 = "16395E", TEAL = "0E9AA7", CYAN = "27C2B6",
      GREEN = "2BA84A", RED = "D9534F", INK = "1E2A38", MUTED = "5B6B7B",
      PANEL = "EEF3F8", ICE = "CFE3F2", WHITE = "FFFFFF", LINEC = "D4DEE8";
const HEAD = "Trebuchet MS", BODY = "Calibri";
const sh = () => ({ type: "outer", color: "0E2A47", blur: 9, offset: 3, angle: 135, opacity: 0.18 });

function pngSize(p){ const b = fs.readFileSync(p); return { w: b.readUInt32BE(16), h: b.readUInt32BE(20) }; }
// вписать картинку в бокс (сохранив пропорции), вернуть центрированные x,y,w,h
function fit(p, bx, by, bw, bh){
  const s = pngSize(p); const r = Math.min(bw / s.w, bh / s.h);
  const w = s.w * r, h = s.h * r;
  return { x: bx + (bw - w) / 2, y: by + (bh - h) / 2, w, h };
}
function framedImg(slide, p, bx, by, bw, bh, pad = 0.12){
  const f = fit(p, bx + pad, by + pad, bw - 2 * pad, bh - 2 * pad);
  slide.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: f.x - pad, y: f.y - pad, w: f.w + 2 * pad, h: f.h + 2 * pad,
    rectRadius: 0.06, fill: { color: WHITE }, line: { color: LINEC, width: 1 }, shadow: sh() });
  slide.addImage({ path: p, x: f.x, y: f.y, w: f.w, h: f.h });
  return f;
}
function header(slide, kicker, title){
  slide.addText(kicker.toUpperCase(), { x: MX, y: 0.42, w: PW - 2 * MX, h: 0.32,
    fontFace: HEAD, fontSize: 12.5, bold: true, color: TEAL, charSpacing: 3, margin: 0 });
  slide.addText(title, { x: MX, y: 0.74, w: PW - 2 * MX, h: 0.85,
    fontFace: HEAD, fontSize: 28, bold: true, color: NAVY, margin: 0 });
}
function chip(slide, x, y, n, d = 0.52, color = TEAL){
  slide.addShape(pres.shapes.OVAL, { x, y, w: d, h: d, fill: { color }, shadow: sh() });
  slide.addText(String(n), { x, y, w: d, h: d, align: "center", valign: "middle",
    fontFace: HEAD, fontSize: 17, bold: true, color: WHITE, margin: 0 });
}
function pageNum(slide, n){
  slide.addText(String(n).padStart(2, "0") + " / 10", { x: PW - 1.7, y: PH - 0.5, w: 1.1, h: 0.3,
    align: "right", fontFace: BODY, fontSize: 10, color: MUTED, margin: 0 });
}

// ============================= СЛАЙД 1 — ТИТУЛ =============================
let s = pres.addSlide(); s.background = { color: NAVY };
// мотив: концентрические «волны сигнала» в правом нижнем углу
[3.4, 2.6, 1.8, 1.0].forEach(d => s.addShape(pres.shapes.OVAL, {
  x: PW - d / 2 - 0.2, y: PH - d / 2 - 0.2, w: d, h: d,
  fill: { color: NAVY, transparency: 100 }, line: { color: CYAN, width: 1.4, transparency: 55 } }));
s.addText("МИНОБРНАУКИ РОССИИ", { x: 0, y: 0.45, w: PW, h: 0.3, align: "center",
  fontFace: BODY, fontSize: 12, color: ICE, charSpacing: 2, margin: 0 });
s.addText("Югорский государственный университет", { x: 0, y: 0.74, w: PW, h: 0.4, align: "center",
  fontFace: HEAD, fontSize: 17, bold: true, color: WHITE, margin: 0 });
s.addText("Инженерная школа цифровых технологий · 01.04.02 Прикладная математика и информатика",
  { x: 0, y: 1.12, w: PW, h: 0.3, align: "center", fontFace: BODY, fontSize: 11.5, color: ICE, margin: 0 });
s.addShape(pres.shapes.RECTANGLE, { x: PW/2 - 1.4, y: 1.62, w: 2.8, h: 0.02, fill: { color: TEAL } });
s.addText("ВЫПУСКНАЯ КВАЛИФИКАЦИОННАЯ РАБОТА · МАГИСТЕРСКАЯ ДИССЕРТАЦИЯ",
  { x: 0, y: 1.85, w: PW, h: 0.3, align: "center", fontFace: HEAD, fontSize: 12.5, bold: true,
    color: CYAN, charSpacing: 1.5, margin: 0 });
s.addText("Разработка системы контроля удалённого доступа на основе анализа траектории изменения сигнала BLE-меток",
  { x: 1.1, y: 2.35, w: PW - 2.2, h: 2.0, align: "center", valign: "middle",
    fontFace: HEAD, fontSize: 31, bold: true, color: WHITE, lineSpacingMultiple: 1.05, margin: 0 });
// нижний блок
s.addText([
  { text: "Выполнил\n", options: { fontSize: 11, color: ICE, breakLine: true } },
  { text: "Сульдин Андрей Валентинович\n", options: { fontSize: 16, bold: true, color: WHITE, breakLine: true } },
  { text: "Группа [указать номер]", options: { fontSize: 12, color: ICE } },
], { x: 1.1, y: 5.05, w: 5.4, h: 1.2, fontFace: BODY, align: "left", valign: "top", margin: 0, lineSpacingMultiple: 1.1 });
s.addText([
  { text: "Научный руководитель\n", options: { fontSize: 11, color: ICE, breakLine: true } },
  { text: "Годовников Евгений Александрович", options: { fontSize: 16, bold: true, color: WHITE } },
], { x: 6.9, y: 5.05, w: 5.3, h: 1.2, fontFace: BODY, align: "left", valign: "top", margin: 0, lineSpacingMultiple: 1.1 });
s.addText("Ханты-Мансийск · 2026", { x: 0, y: PH - 0.6, w: PW, h: 0.35, align: "center",
  fontFace: HEAD, fontSize: 12, bold: true, color: ICE, charSpacing: 1, margin: 0 });

// ============================= СЛАЙД 2 — АКТУАЛЬНОСТЬ =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "01 · Введение", "Актуальность темы");
const act = [
  ["Доступ «по присутствию»", "Бесконтактные СКУД на BLE востребованы: поддержка во всех смартфонах, доступ предоставляется автоматически при приближении носителя."],
  ["Сигнал RSSI зашумлён", "Переотражения, экранирование телом, ориентация антенны и помехи искажают уровень сигнала."],
  ["Порог ненадёжен", "Решение по одному мгновенному RSSI даёт ложные срабатывания, реагирует на статичную метку и ретрансляцию."],
  ["Решение — траектория", "Анализ динамики RSSI во времени (зоны «далеко»/«близко» и удержание) повышает устойчивость к шуму."],
];
let ay = 1.75;
act.forEach((it, i) => {
  chip(s, MX, ay, i + 1, 0.5, i === 3 ? GREEN : TEAL);
  s.addText([
    { text: it[0] + "\n", options: { fontSize: 15.5, bold: true, color: NAVY, breakLine: true } },
    { text: it[1], options: { fontSize: 12.5, color: INK } },
  ], { x: MX + 0.7, y: ay - 0.06, w: 6.7, h: 1.15, fontFace: BODY, margin: 0, valign: "top", lineSpacingMultiple: 1.02 });
  ay += 1.25;
});
// правый акцент-панель
s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 8.5, y: 1.85, w: 4.1, h: 4.55, rectRadius: 0.1,
  fill: { color: NAVY }, shadow: sh() });
s.addText("Ключевая идея", { x: 8.8, y: 2.2, w: 3.5, h: 0.4, fontFace: HEAD, fontSize: 13, bold: true,
  color: CYAN, charSpacing: 1, margin: 0 });
s.addText("Решение о доступе — по траектории сигнала во времени, а не по одному порогу RSSI.",
  { x: 8.8, y: 2.75, w: 3.5, h: 1.7, fontFace: HEAD, fontSize: 21, bold: true, color: WHITE,
    margin: 0, valign: "top", lineSpacingMultiple: 1.05 });
s.addText("⟶  устойчивость к шуму и несанкционированным срабатываниям",
  { x: 8.8, y: 5.35, w: 3.5, h: 0.9, fontFace: BODY, fontSize: 12.5, italic: true, color: ICE, margin: 0 });
pageNum(s, 2);

// ============================= СЛАЙД 3 — ЦЕЛЬ И ЗАДАЧИ =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "02 · Введение", "Цель и задачи");
s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: MX, y: 1.7, w: PW - 2 * MX, h: 1.05, rectRadius: 0.08,
  fill: { color: PANEL }, line: { color: TEAL, width: 1.4 } });
s.addText([
  { text: "ЦЕЛЬ.  ", options: { fontSize: 14, bold: true, color: TEAL } },
  { text: "Разработать систему контроля удалённого доступа, принимающую решение на основе анализа траектории изменения сигнала BLE-метки, и подтвердить её работоспособность.",
    options: { fontSize: 14.5, color: INK } },
], { x: MX + 0.25, y: 1.78, w: PW - 2 * MX - 0.5, h: 0.9, fontFace: BODY, valign: "middle", margin: 0, lineSpacingMultiple: 1.0 });
const tasks = [
  "Обзор технологии BLE, методов оценки расстояния по RSSI и подходов к контролю доступа; обоснование выбора метода анализа траектории.",
  "Разработка модели и архитектуры системы контроля доступа.",
  "Разработка алгоритма анализа траектории RSSI: зоны «далеко»/«близко», подсчёт удержания, решение по гистерезису.",
  "Реализация компонентов: генератор и сканер меток, анализатор траектории, мобильное приложение, исполнительный модуль управления замком.",
  "Тестирование системы и оценка работоспособности (имитационное моделирование и натурные измерения).",
];
let ty = 3.05;
tasks.forEach((t, i) => {
  chip(s, MX, ty, i + 1, 0.46, NAVY);
  s.addText(t, { x: MX + 0.65, y: ty - 0.02, w: PW - 2 * MX - 0.7, h: 0.7, fontFace: BODY,
    fontSize: 13, color: INK, margin: 0, valign: "top", lineSpacingMultiple: 1.0 });
  ty += 0.82;
});
pageNum(s, 3);

// ============================= СЛАЙД 4 — ОБЪЕКТ И ПРЕДМЕТ =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "03 · Введение", "Объект и предмет исследования");
function bigCard(x, label, color, text){
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y: 1.95, w: 5.75, h: 4.3, rectRadius: 0.1,
    fill: { color: WHITE }, line: { color: LINEC, width: 1 }, shadow: sh() });
  s.addShape(pres.shapes.OVAL, { x: x + 0.4, y: 2.4, w: 0.9, h: 0.9, fill: { color } });
  s.addText(label[0], { x: x + 0.4, y: 2.4, w: 0.9, h: 0.9, align: "center", valign: "middle",
    fontFace: HEAD, fontSize: 30, bold: true, color: WHITE, margin: 0 });
  s.addText(label, { x: x + 1.5, y: 2.55, w: 3.9, h: 0.7, fontFace: HEAD, fontSize: 20, bold: true,
    color: NAVY, margin: 0, valign: "middle" });
  s.addText(text, { x: x + 0.45, y: 3.6, w: 4.9, h: 2.4, fontFace: BODY, fontSize: 15, color: INK,
    margin: 0, valign: "top", lineSpacingMultiple: 1.12 });
}
bigCard(MX, "Объект", TEAL, "Системы контроля и управления удалённым доступом, использующие беспроводные BLE-метки.");
bigCard(7.0, "Предмет", GREEN, "Методы и алгоритмы анализа траектории изменения уровня сигнала (RSSI) BLE-меток во времени для принятия решения о предоставлении доступа.");
pageNum(s, 4);

// ============================= СЛАЙД 5 — МЕТОДЫ И СРЕДСТВА =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "04 · Введение", "Методы и средства");
s.addText("Методы", { x: MX, y: 1.7, w: 5.5, h: 0.4, fontFace: HEAD, fontSize: 16, bold: true, color: TEAL, margin: 0 });
const methods = [
  "Системный анализ и классификация при обзоре предметной области",
  "Модульное проектирование архитектуры системы",
  "Гистерезис зон сигнала и аппарат конечных автоматов",
  "Имитационное моделирование и натурные измерения",
];
let my = 2.25;
methods.forEach(m => {
  s.addShape(pres.shapes.OVAL, { x: MX + 0.05, y: my + 0.07, w: 0.16, h: 0.16, fill: { color: TEAL } });
  s.addText(m, { x: MX + 0.45, y: my - 0.06, w: 5.2, h: 0.7, fontFace: BODY, fontSize: 13.5, color: INK,
    margin: 0, valign: "top", lineSpacingMultiple: 1.0 });
  my += 0.92;
});
// стек технологий — чипы
s.addText("Технологии и инструменты", { x: 6.75, y: 1.7, w: 6, h: 0.4, fontFace: HEAD, fontSize: 16, bold: true, color: GREEN, margin: 0 });
const stack = ["Flutter · Dart", "Android", "flutter_blue_plus", "flutter_ble_peripheral",
  "permission_handler", "shared_preferences", "crypto · HMAC-SHA256", "HM-10 · BLE → RS-485"];
let cx = 6.75, cy = 2.25; const cw = 2.95, chh = 0.62, gap = 0.18;
stack.forEach((t, i) => {
  const col = i % 2, row = Math.floor(i / 2);
  const x = 6.75 + col * (cw + gap), y = 2.25 + row * (chh + gap);
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x, y, w: cw, h: chh, rectRadius: 0.08,
    fill: { color: PANEL }, line: { color: LINEC, width: 1 } });
  s.addText(t, { x: x + 0.1, y, w: cw - 0.2, h: chh, align: "center", valign: "middle",
    fontFace: BODY, fontSize: 12.5, bold: true, color: NAVY, margin: 0 });
});
s.addText("Единая кодовая база (Flutter) — весь цикл в одном приложении: генерация метки, приём и анализ сигнала, решение и отправка команды замку.",
  { x: 6.75, y: 5.55, w: 6.1, h: 0.9, fontFace: BODY, fontSize: 12, italic: true, color: MUTED, margin: 0, lineSpacingMultiple: 1.05 });
pageNum(s, 5);

// ============================= СЛАЙД 6 — ГЛАВА 1 (СРАВНЕНИЕ) =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "Глава 1 · Аналитическая часть", "Сравнение подходов к принятию решения");
const cmp = [
  [RED, "Пороговый подход", "Доступ при превышении порога RSSI. Реагирует на любой сильный сигнал → ложные срабатывания на шуме, статичной метке и ретрансляции."],
  [GREEN, "Анализ траектории", "Требует характерной динамики «далеко → близко» с удержанием в зонах. Случайные всплески сигнала отсекаются."],
];
let yy = 1.85;
cmp.forEach(c => {
  s.addShape(pres.shapes.RECTANGLE, { x: MX, y: yy, w: 0.1, h: 1.55, fill: { color: c[0] } });
  s.addText(c[1], { x: MX + 0.28, y: yy, w: 5.6, h: 0.4, fontFace: HEAD, fontSize: 16, bold: true, color: NAVY, margin: 0 });
  s.addText(c[2], { x: MX + 0.28, y: yy + 0.42, w: 5.6, h: 1.15, fontFace: BODY, fontSize: 13, color: INK, margin: 0, valign: "top", lineSpacingMultiple: 1.05 });
  yy += 1.8;
});
s.addText("BLE выбрана среди беспроводных технологий (RFID/NFC/UWB/Wi-Fi): дальность единицы–десятки метров, энергоэффективность и поддержка в смартфонах (таблица 1).",
  { x: MX, y: 5.5, w: 5.95, h: 1.0, fontFace: BODY, fontSize: 12, italic: true, color: MUTED, margin: 0, lineSpacingMultiple: 1.05 });
const f6 = framedImg(s, "pres_img/img04.png", 6.95, 1.8, 5.9, 4.0);
s.addText("Рис. — пороговый подход даёт ложное срабатывание; анализ траектории — отказ.",
  { x: 6.95, y: 5.85, w: 5.9, h: 0.5, align: "center", fontFace: BODY, fontSize: 11, italic: true, color: MUTED, margin: 0 });
pageNum(s, 6);

// ============================= СЛАЙД 7 — ГЛАВА 2 (АРХИТЕКТУРА) =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "Глава 2 · Проектная часть", "Архитектура системы");
const arch = [
  ["Сканер", "приём рекламных пакетов BLE и измерение RSSI(t)"],
  ["Анализатор", "анализ траектории, сверка с базой авторизованных, решение"],
  ["Исполнитель", "модуль HM-10: мост BLE → RS-485 к контроллеру замка"],
];
let hy = 2.05;
arch.forEach((a, i) => {
  chip(s, MX, hy, i + 1, 0.46, NAVY);
  s.addText([
    { text: a[0] + "  ", options: { fontSize: 14, bold: true, color: NAVY } },
    { text: "— " + a[1], options: { fontSize: 12.5, color: INK } },
  ], { x: MX + 0.62, y: hy - 0.04, w: 4.5, h: 1.0, fontFace: BODY, margin: 0, valign: "top", lineSpacingMultiple: 1.0 });
  hy += 1.28;
});
s.addText("Модульность: ядро решения (гистерезис) отделено от интерфейса и тестируется автономно.",
  { x: MX, y: 5.95, w: 5.0, h: 0.9, fontFace: BODY, fontSize: 12, italic: true, color: MUTED, margin: 0, lineSpacingMultiple: 1.05 });
framedImg(s, "pres_img/img03.png", 5.65, 1.95, 7.2, 4.35);
s.addText("Рис. 3 — структурная схема системы контроля доступа",
  { x: 5.65, y: 6.32, w: 7.2, h: 0.4, align: "center", fontFace: BODY, fontSize: 11, italic: true, color: MUTED, margin: 0 });
pageNum(s, 7);

// ============================= СЛАЙД 8 — ГЛАВА 2 (АЛГОРИТМ) =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "Глава 2 · Проектная часть", "Алгоритм: гистерезис зон сигнала");
const algo = [
  ["Две зоны по порогам RSSI", "«далеко» (B) и «близко» (A); между ними — зона нечувствительности."],
  ["Счётчики удержания", "B — «взвод» при удержании «далеко», A — удержание «близко»."],
  ["Условие доступа", "удержание «близко» (A > Y) после взвода «далеко» (B > X), с защёлкой гистерезиса."],
  ["Без фильтрации сигнала", "ни фильтра Калмана, ни сглаживания — устойчивость обеспечивает сама логика."],
];
let gy = 2.0;
algo.forEach((a, i) => {
  chip(s, MX, gy, i + 1, 0.46, TEAL);
  s.addText([
    { text: a[0] + "\n", options: { fontSize: 14, bold: true, color: NAVY, breakLine: true } },
    { text: a[1], options: { fontSize: 12.5, color: INK } },
  ], { x: MX + 0.62, y: gy - 0.04, w: 6.4, h: 1.05, fontFace: BODY, margin: 0, valign: "top", lineSpacingMultiple: 1.0 });
  gy += 1.18;
});
framedImg(s, "pres_img/algo.png", 8.7, 1.55, 4.1, 5.55);
pageNum(s, 8);

// ============================= СЛАЙД 9 — ГЛАВА 3 (РЕАЛИЗАЦИЯ И ТЕСТ) =============================
s = pres.addSlide(); s.background = { color: WHITE }; header(s, "Глава 3 · Реализация и тестирование", "Реализация и тестирование");
// два скриншота
framedImg(s, "pres_img/img05.png", 0.6, 1.75, 2.55, 4.25, 0.08);
s.addText("Вкладка «Сканер»", { x: 0.6, y: 6.02, w: 2.55, h: 0.3, align: "center", fontFace: BODY, fontSize: 10.5, color: MUTED, margin: 0 });
framedImg(s, "pres_img/img06.png", 3.2, 1.75, 2.55, 4.25, 0.08);
s.addText("Вкладка «Шлюз»", { x: 3.2, y: 6.02, w: 2.55, h: 0.3, align: "center", fontFace: BODY, fontSize: 10.5, color: MUTED, margin: 0 });
// результат моделирования
const f9 = framedImg(s, "pres_img/img07.png", 6.0, 1.7, 6.85, 3.0);
s.addText("Имитационное моделирование: доступ при приближении, сброс при удалении.",
  { x: 6.0, y: 4.72, w: 6.85, h: 0.35, align: "center", fontFace: BODY, fontSize: 10.5, italic: true, color: MUTED, margin: 0 });
// итоги теста
s.addShape(pres.shapes.OVAL, { x: 6.05, y: 5.3, w: 0.16, h: 0.16, fill: { color: GREEN } });
s.addText("Доступ предоставляется при целенаправленном приближении; на статичной метке — ноль ложных срабатываний.",
  { x: 6.45, y: 5.18, w: 6.45, h: 0.55, fontFace: BODY, fontSize: 12.5, color: INK, margin: 0, valign: "top", lineSpacingMultiple: 1.0 });
s.addShape(pres.shapes.OVAL, { x: 6.05, y: 5.95, w: 0.16, h: 0.16, fill: { color: GREEN } });
s.addText("Натурный проход носителя и проверка канала управления (HM-10, петлевой тест) подтверждены.",
  { x: 6.45, y: 5.83, w: 6.45, h: 0.55, fontFace: BODY, fontSize: 12.5, color: INK, margin: 0, valign: "top", lineSpacingMultiple: 1.0 });
s.addText("Подробная демонстрация работы приложения — после доклада.",
  { x: 6.0, y: 6.55, w: 6.85, h: 0.4, fontFace: BODY, fontSize: 12, italic: true, bold: true, color: TEAL, margin: 0 });
pageNum(s, 9);

// ============================= СЛАЙД 10 — ЗАКЛЮЧЕНИЕ =============================
s = pres.addSlide(); s.background = { color: NAVY };
[3.0, 2.2, 1.4].forEach(d => s.addShape(pres.shapes.OVAL, { x: -d / 2 + 0.1, y: -d / 2 + 0.1, w: d, h: d,
  fill: { color: NAVY, transparency: 100 }, line: { color: CYAN, width: 1.3, transparency: 60 } }));
s.addText("ЗАКЛЮЧЕНИЕ", { x: MX, y: 0.5, w: PW - 2 * MX, h: 0.4, fontFace: HEAD, fontSize: 12.5, bold: true, color: CYAN, charSpacing: 3, margin: 0 });
s.addText("Цель достигнута — система разработана и работоспособность подтверждена",
  { x: MX, y: 0.92, w: PW - 2 * MX, h: 0.8, fontFace: HEAD, fontSize: 25, bold: true, color: WHITE, margin: 0, lineSpacingMultiple: 1.0 });
const res = [
  ["Разработано", "архитектура системы и алгоритм анализа траектории на основе гистерезиса зон сигнала."],
  ["Реализовано", "мобильное приложение (Flutter, Android): сканер, генератор и метка, управление замком BLE → RS-485; rolling-code и доступ по звонку."],
  ["Проведено", "тестирование (моделирование + натурные измерения): корректный доступ при приближении, отсутствие ложных срабатываний."],
];
let ry = 2.1;
res.forEach(r => {
  s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: MX, y: ry, w: 7.4, h: 1.0, rectRadius: 0.08, fill: { color: NAVY2 } });
  s.addText(r[0], { x: MX + 0.25, y: ry, w: 2.0, h: 1.0, fontFace: HEAD, fontSize: 15, bold: true, color: CYAN, valign: "middle", margin: 0 });
  s.addText(r[1], { x: MX + 2.2, y: ry, w: 5.0, h: 1.0, fontFace: BODY, fontSize: 12, color: ICE, valign: "middle", margin: 0, lineSpacingMultiple: 1.0 });
  ry += 1.12;
});
// правая колонка: значимость + перспективы
s.addShape(pres.shapes.ROUNDED_RECTANGLE, { x: 8.5, y: 2.1, w: 4.1, h: 1.62, rectRadius: 0.08, fill: { color: TEAL } });
s.addText([{ text: "Практическая значимость\n", options: { fontSize: 13, bold: true, color: WHITE, breakLine: true } },
  { text: "Бесконтактный контроль доступа на одной точке прохода без развёртывания дополнительной инфраструктуры.", options: { fontSize: 12, color: WHITE } }],
  { x: 8.75, y: 2.28, w: 3.65, h: 1.3, fontFace: BODY, margin: 0, valign: "top", lineSpacingMultiple: 1.03 });
s.addText("Перспективы развития", { x: 8.5, y: 3.95, w: 4.1, h: 0.35, fontFace: HEAD, fontSize: 13, bold: true, color: CYAN, margin: 0 });
["Несколько приёмников — оценка координат", "ML-классификация траекторий", "Защита от атак ретрансляции", "Интеграция с существующими СКУД"].forEach((t, i) => {
  s.addShape(pres.shapes.OVAL, { x: 8.55, y: 4.42 + i * 0.42, w: 0.13, h: 0.13, fill: { color: CYAN } });
  s.addText(t, { x: 8.85, y: 4.32 + i * 0.42, w: 3.8, h: 0.4, fontFace: BODY, fontSize: 12, color: ICE, margin: 0, valign: "top" });
});
s.addText("Спасибо за внимание!", { x: MX, y: PH - 0.75, w: 7.0, h: 0.45, fontFace: HEAD, fontSize: 18, bold: true, color: WHITE, margin: 0 });
s.addText("Сульдин А.В. · 2026", { x: PW - 4.0, y: PH - 0.7, w: 3.3, h: 0.4, align: "right", fontFace: BODY, fontSize: 12, color: ICE, margin: 0 });

pres.writeFile({ fileName: "presentation.pptx" }).then(f => console.log("OK:", f));
