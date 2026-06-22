const fs = require('fs');
const path = require('path');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel,
  AlignmentType, PageBreak, BorderStyle, PageOrientation,
} = require('docx');

const data = JSON.parse(fs.readFileSync(path.join(__dirname, '..', '_doklad.json'), 'utf8'));
const OUT = process.argv[2] || 'C:\\Users\\krealix\\Desktop\\Доклад и вопросы — ВКР Сульдин.docx';

const NAVY = '0E2A47';
const TEAL = '0E6E78';
const MUTED = '5B6B7B';

function body(text, { line = 360, after = 140, size = 28, italic = false, align = AlignmentType.JUSTIFIED, color } = {}) {
  return new Paragraph({
    spacing: { line, after },
    alignment: align,
    children: [new TextRun({ text, size, italics: italic, color })],
  });
}

function leadQA(num, q) {
  return new Paragraph({
    spacing: { before: 220, after: 80, line: 276 },
    children: [new TextRun({ text: `${num}. ${q}`, bold: true, size: 28, color: NAVY })],
  });
}

const children = [];

// --- Титул ---
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { after: 120 },
  children: [new TextRun({ text: 'Доклад к защите выпускной квалификационной работы', bold: true, size: 32, color: NAVY })],
}));
children.push(new Paragraph({
  alignment: AlignmentType.CENTER, spacing: { after: 240 },
  border: { bottom: { style: BorderStyle.SINGLE, size: 6, color: TEAL, space: 8 } },
  children: [new TextRun({ text: `«${data.tema}»`, italics: true, size: 26, color: MUTED })],
}));
children.push(body(`Студент: ${data.student}`, { line: 276, after: 40 }));
children.push(body(`Научный руководитель: ${data.ruk}`, { line: 276, after: 40 }));
children.push(body('Регламент доклада: ориентировочно 7–9 минут.', { line: 276, after: 240, color: MUTED }));

// --- Текст доклада ---
children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('Текст доклада')] }));
data.speech.forEach(([title, text], i) => {
  children.push(new Paragraph({
    heading: HeadingLevel.HEADING_2,
    children: [new TextRun(`Слайд ${i + 1}. ${title}`)],
  }));
  children.push(body(text, { line: 360, after: 160 }));
});

// --- Вопросы и ответы ---
children.push(new Paragraph({ children: [new PageBreak()] }));
children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('Возможные вопросы и ответы')] }));
data.qa.forEach(([q, a], i) => {
  children.push(leadQA(i + 1, q));
  children.push(body(a, { line: 276, after: 100 }));
});

// --- Вопросы по теории (опционально, из _theory_qa.json) ---
const theoryPath = path.join(__dirname, '..', '_theory_qa.json');
if (fs.existsSync(theoryPath)) {
  const theory = JSON.parse(fs.readFileSync(theoryPath, 'utf8')).theory || [];
  children.push(new Paragraph({ children: [new PageBreak()] }));
  children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('Вопросы по теории (Глава 1)')] }));
  let lastCluster = null;
  let n = 0;
  theory.forEach(({ cluster, q, a }) => {
    if (cluster && cluster !== lastCluster) {
      children.push(new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(cluster)] }));
      lastCluster = cluster;
    }
    n += 1;
    children.push(leadQA(n, q));
    children.push(body(a, { line: 276, after: 100 }));
  });
}

// --- Опорные ответы (кратко) — из _short_qa.json ---
const shortPath = path.join(__dirname, '..', '_short_qa.json');
if (fs.existsSync(shortPath)) {
  const s = JSON.parse(fs.readFileSync(shortPath, 'utf8'));
  children.push(new Paragraph({ children: [new PageBreak()] }));
  children.push(new Paragraph({ heading: HeadingLevel.HEADING_1, children: [new TextRun('Опорные ответы (для быстрого повторения)')] }));
  const block = (title, items) => {
    children.push(new Paragraph({ heading: HeadingLevel.HEADING_2, children: [new TextRun(title)] }));
    items.forEach(([tag, ans], i) => {
      children.push(new Paragraph({
        spacing: { before: 30, after: 90, line: 264 },
        children: [
          new TextRun({ text: `${i + 1}. ${tag}. `, bold: true, color: NAVY }),
          new TextRun({ text: ans, size: 26 }),
        ],
      }));
    });
  };
  block('По системе и реализации', s.sys);
  block('По теории', s.theory);
}

const doc = new Document({
  styles: {
    default: { document: { run: { font: 'Times New Roman', size: 28 } } },
    paragraphStyles: [
      { id: 'Heading1', name: 'Heading 1', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 32, bold: true, font: 'Times New Roman', color: NAVY },
        paragraph: { spacing: { before: 240, after: 160 }, outlineLevel: 0 } },
      { id: 'Heading2', name: 'Heading 2', basedOn: 'Normal', next: 'Normal', quickFormat: true,
        run: { size: 28, bold: true, font: 'Times New Roman', color: TEAL },
        paragraph: { spacing: { before: 200, after: 80 }, outlineLevel: 1 } },
    ],
  },
  sections: [{
    properties: { page: {
      size: { width: 11906, height: 16838, orientation: PageOrientation.PORTRAIT },
      margin: { top: 1440, right: 1134, bottom: 1440, left: 1418 },
    } },
    children,
  }],
});

Packer.toBuffer(doc).then(buf => { fs.writeFileSync(OUT, buf); console.log('saved:', OUT, buf.length, 'bytes'); });
