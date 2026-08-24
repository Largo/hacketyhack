const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  PageNumber, Footer, LevelFormat, convertMillimetersToTwip, TabStopType,
} = require("docx");
const fs = require("fs");

const FONT = "Arial";
const SIZE = 26;      // 13pt
const IND = 300;      // ~15pt Einzug wie im Original
const GRAY = "808080";

// ---- Helfer -----------------------------------------------------------
const run = (text, opts = {}) => new TextRun({ text, font: FONT, size: SIZE, ...opts });
const ph  = (text) => run(text, { color: GRAY });   // Platzhalter (grau)

// Fliesstext-Absatz; Strings = normal, Objekte {t, ...} = formatiert
const p = (parts, opts = {}) => new Paragraph({
  indent: { left: opts.indent === undefined ? IND : opts.indent },
  spacing: { after: opts.after === undefined ? 240 : opts.after, line: 276 },
  children: (Array.isArray(parts) ? parts : [parts]).map((x) =>
    typeof x === "string" ? run(x) : (x instanceof TextRun ? x : run(x.t, x))),
});

// Traktandum-Überschrift (fett, ohne Einzug)
const h = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_1,
  spacing: { before: 480, after: 300 },
  children: [run(text, { bold: true })],
});

// Zwischentitel (fett, mit Einzug)
const h2 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_2,
  indent: { left: IND },
  spacing: { before: 480, after: 300 },
  children: [run(text, { bold: true })],
});

// Beschriftetes Feld: "Label: <Platzhalter>"
const field = (label, placeholder) => p([
  run(label + ": ", { bold: true }), ph(placeholder),
], { indent: 0 , after: 160 });

// ABSTIMMUNG-Zeile (komplett fett)
const vote = (placeholder) => p([
  run("ABSTIMMUNG: ", { bold: true }), run(placeholder, { bold: true, color: GRAY }),
], { before: 240, after: 240 });

const bullet = (text) => new Paragraph({
  numbering: { reference: "striche", level: 0 },
  spacing: { after: 120, line: 276 },
  children: [ph(text)],
});

const traktandum = (text) => new Paragraph({
  numbering: { reference: "traktanden", level: 0 },
  spacing: { after: 60, line: 276 },
  children: [run(text)],
});

const leer = (after = 0) => new Paragraph({ spacing: { after }, children: [run("")] });

// ---- Dokument ---------------------------------------------------------
const doc = new Document({
  creator: "Yetnet Rupperswil",
  title: "Protokoll Generalversammlung Yetnet Rupperswil 2026",
  description: "Vorlage für das Protokoll der Generalversammlung",
  styles: {
    default: {
      document: { run: { font: FONT, size: SIZE } },
      heading1: { run: { font: FONT, size: SIZE, bold: true, color: "000000" } },
      heading2: { run: { font: FONT, size: SIZE, bold: true, color: "000000" } },
    },
  },
  numbering: {
    config: [
      {
        reference: "traktanden",
        levels: [{
          level: 0, format: LevelFormat.DECIMAL, text: "%1.", alignment: AlignmentType.START,
          style: { paragraph: { indent: { left: 660, hanging: 360 } },
                   run: { font: FONT, size: SIZE } },
        }],
      },
      {
        reference: "striche",
        levels: [{
          level: 0, format: LevelFormat.BULLET, text: "-", alignment: AlignmentType.START,
          style: { paragraph: { indent: { left: 660, hanging: 360 } },
                   run: { font: FONT, size: SIZE } },
        }],
      },
    ],
  },
  sections: [{
    properties: {
      page: {
        margin: {
          top: convertMillimetersToTwip(25), bottom: convertMillimetersToTwip(20),
          left: convertMillimetersToTwip(25), right: convertMillimetersToTwip(25),
          footer: convertMillimetersToTwip(12),
        },
      },
    },
    footers: {
      default: new Footer({
        children: [new Paragraph({
          alignment: AlignmentType.CENTER,
          children: [new TextRun({ children: [PageNumber.CURRENT], font: FONT, size: SIZE })],
        })],
      }),
    },
    children: [
      // Titel
      new Paragraph({
        spacing: { after: 480 },
        children: [new TextRun({
          text: "Protokoll Generalversammlung Yetnet Rupperswil",
          font: FONT, size: 40, bold: true, smallCaps: true,
        })],
      }),

      field("Datum", "[Wochentag], [TT]. [Monat] 2026 um [HH.MM] Uhr"),
      field("Ort", "[Veranstaltungsort], Rupperswil"),

      h2("Präsenz"),
      p([run("Anwesende Vorstandsmitglieder: "), ph("[Vorname Name (KÜR)], [Vorname Name (KÜR)], [Vorname Name (KÜR)]")], { after: 160 }),
      p([run("Entschuldigte Vorstandsmitglieder: "), ph("[Vorname Name (KÜR)] / -")], { after: 160 }),
      p([run("Gäste: "), ph("[Vorname Name (Funktion, Firma)]")], { after: 160 }),

      h2("Traktanden"),
      traktandum("Protokoll der letzten Generalversammlung"),
      traktandum("Jahresbericht des Präsidenten"),
      traktandum("Bilanz- und Betriebsrechnung 2025"),
      traktandum("Entlastung der Verwaltung"),
      traktandum("Ergänzungswahlen in den Vorstand / Austritte"),
      traktandum("Wahl der Revisionsstelle"),
      traktandum("Voranschlag 2026"),
      traktandum("Verschiedenes und Umfrage"),

      h2("Begrüssung und Einleitung"),
      p([
        run("Der Präsident, "), ph("[Vorname Name]"),
        run(", begrüsst alle anwesenden Genossenschafter und Genossenschafterinnen zur "),
        ph("48."), run(" Generalversammlung der Yetnet Rupperswil."),
      ]),
      p([
        run("Anwesend sind insgesamt "), ph("[Anzahl]"),
        run(" Personen (inkl. Paare, Gäste, etc.). Einschliesslich der "),
        ph("[Anzahl]"), run(" Vorstandsmitglieder sind "), ph("[Anzahl]"),
        run(" stimmberechtigte Genossenschafter anwesend. Das absolute Mehr beträgt "),
        ph("[Anzahl]"), run(" Stimmen."),
      ]),
      p([
        ph("[KÜR]"),
        run(" stellt fest, dass die Einladung fristgerecht versandt/publiziert wurde und die Unterlagen bei der Gemeindekanzlei zur Einsicht auflagen. Einwände zur Traktandenliste gibt es keine."),
      ]),

      // 1
      h("1. Protokoll der letzten Generalversammlung"),
      p([
        run("Das Protokoll der letzten Generalversammlung vom "), ph("[TT. Monat JJJJ]"),
        run(" lag bei der Gemeindekanzlei zur Einsicht auf. Zusätzlich wurde es auf der Yetnet Rupperswil-Homepage publiziert."),
      ]),
      p([ph("[Es gibt keine Einwände oder Fragen zum Protokoll.]")]),
      vote("[Das Protokoll wird einstimmig genehmigt.]"),

      // 2
      h("2. Jahresbericht des Präsidenten"),
      p([
        ph("[Vorname Name (KÜR)]"),
        run(" präsentiert seinen Jahresbericht und geht insbesondere auf folgende Punkte ein:"),
      ], { after: 160 }),
      bullet("[Thema: Kurzbeschrieb]"),
      bullet("[Thema: Kurzbeschrieb]"),
      bullet("[Thema: Kurzbeschrieb]"),

      // 3
      h("3. Bilanz- und Betriebsrechnung 2025"),
      p([run("Die Betriebsrechnung, Bilanz und der Revisorenbericht lagen vor der Versammlung in der Gemeindekanzlei auf. "), ph("[Bemerkungen zum Revisorenbericht.]")]),
      p([ph("[Wer führt durch die Zahlen? Wesentliche Positionen und Erläuterungen.]")]),
      p([run("Das Jahr 2025 wurde mit einem "), ph("[Gewinn / Verlust]"), run(" von CHF "), ph("[Betrag]"), run(" abgeschlossen. "), ph("[Ergänzende Bemerkungen.]")]),
      p([run("Fragen aus der Versammlung:")], { after: 160 }),
      p([ph("[Frage aus der Versammlung]")], { after: 120 }),
      p([ph("[Antwort des Vorstands]")]),

      // 4
      h("4. Entlastung der Verwaltung"),
      vote("[Die Entlastung wird einstimmig erteilt, die Bilanz und Erfolgsrechnung genehmigt.]"),

      // 5
      h("5. Ergänzungswahlen in den Vorstand / Austritte"),
      p([ph("[KÜR]"), run(" teilt mit, dass "), ph("[Vorname Name]"), run(" nach "), ph("[Anzahl]"), run(" Jahren Tätigkeit für die YeRu den Vorstand verlässt.")]),
      p([ph("[Vorstellung der Kandidatinnen und Kandidaten.]")]),
      p([ph("[Vorgehen bei der Wahl (einzeln / in globo) und allfällige Diskussion.]")]),
      new Paragraph({
        indent: { left: IND }, spacing: { before: 240, after: 120, line: 276 },
        children: [run("ABSTIMMUNG: ", { bold: true }), run("[Vorname Name] wird in den Vorstand gewählt.", { bold: true, color: GRAY })],
      }),
      p([ph("[Anzahl]x Ja")], { after: 60 }),
      p([ph("[Anzahl]x Nein")], { after: 60 }),
      p([ph("[Anzahl]x Enthaltungen")]),
      p([ph("[Dank an die zurücktretenden Vorstandsmitglieder.]")]),

      // 6
      h("6. Wahl der Revisionsstelle"),
      p([run("Der Vorstand schlägt vor, die Firma "), ph("[Firma]"), run(" weiterhin als Revisionsstelle zu beauftragen.")]),
      vote("[Firma] wird einstimmig als Revisionsstelle gewählt."),

      // 7
      h("7. Voranschlag 2026"),
      p([run("Das Budget 2026 wird auf dem Bildschirm präsentiert und einige Positionen genauer erläutert.")]),
      p([ph("[Fragen zum Budget / keine Fragen zum Budget.]")]),
      vote("[Das Budget wird einstimmig genehmigt.]"),

      // 8
      h("8. Verschiedenes und Umfrage"),
      p([ph("[Wortmeldungen aus der Versammlung / keine weiteren Wortmeldungen.]")]),
      p([run("Die Generalversammlung wurde um ", { bold: true }), run("[HH.MM]", { bold: true, color: GRAY }), run(" Uhr beendet.", { bold: true })]),
      p([ph("[Hinweis auf Apéro / Ausklang der Versammlung.]")]),

      // Unterschriften
      leer(240),
      p([run("Rupperswil, "), ph("[TT. Monat 2026]")], { after: 480 }),
      new Paragraph({
        indent: { left: IND },
        tabStops: [{ type: TabStopType.LEFT, position: 5000 }],
        spacing: { after: 960 },
        children: [run("Aktuar:\tPräsident:")],
      }),
      new Paragraph({
        indent: { left: IND },
        tabStops: [{ type: TabStopType.LEFT, position: 5000 }],
        children: [ph("[Vorname Name]\t[Vorname Name]")],
      }),
    ],
  }],
});

Packer.toBuffer(doc).then((b) => {
  fs.writeFileSync(process.argv[2], b);
  console.log("geschrieben:", process.argv[2], b.length, "bytes");
});
