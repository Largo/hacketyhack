// Clogs' Qt backend, C side.
//
// There is no maintained Ruby binding for Qt 5 or 6: qtbindings is Qt 4.8 and
// Ubuntu dropped Qt 4 years ago. Qt is C++ and cannot be reached through FFI
// directly, so this is the missing piece -- a C-callable surface over exactly
// the Qt that Clogs needs, which the Ruby side drives through Fiddle. It is
// the same shape as the C API libui offers, which is why the Ruby half of this
// backend looks like the others.
//
// Build with clogs/ext/qt/build.sh, or `rake qt:build` from the repo root.

#include <QApplication>
#include <QWidget>
#include <QPainter>
#include <QPainterPath>
#include <QTimer>
#include <QImage>
#include <QFont>
#include <QFontMetricsF>
#include <QLinearGradient>
#include <QMessageBox>
#include <QInputDialog>
#include <QFileDialog>
#include <QCloseEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPaintEvent>
#include <QVBoxLayout>
#include <QLoggingCategory>
#include <QDir>
#include <QFile>
#include <cstdlib>
#include <unistd.h>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

extern "C" {

// ---- callbacks into Ruby ------------------------------------------------

typedef void (*PaintCb)(void *canvas, void *painter, double width, double height);
typedef void (*MouseCb)(void *canvas, double x, double y, int down, int up, int held, int mods);
typedef int (*KeyCb)(void *canvas, const char *text, const char *ext, int mods, int up);
typedef void (*CrossCb)(void *canvas, int left);
typedef void (*CloseCb)(void *window);
typedef void (*TimerCb)(int id);

static PaintCb g_paint = nullptr;
static MouseCb g_mouse = nullptr;
static KeyCb g_key = nullptr;
static CrossCb g_cross = nullptr;
static CloseCb g_close = nullptr;
static TimerCb g_timer = nullptr;

void clogs_qt_on_paint(PaintCb cb) { g_paint = cb; }
void clogs_qt_on_mouse(MouseCb cb) { g_mouse = cb; }
void clogs_qt_on_key(KeyCb cb) { g_key = cb; }
void clogs_qt_on_crossed(CrossCb cb) { g_cross = cb; }
void clogs_qt_on_close(CloseCb cb) { g_close = cb; }
void clogs_qt_on_timer(TimerCb cb) { g_timer = cb; }

// ---- helpers ------------------------------------------------------------

static QColor rgba_color(unsigned int rgba) {
  return QColor((rgba >> 24) & 0xff, (rgba >> 16) & 0xff, (rgba >> 8) & 0xff, rgba & 0xff);
}

// Clogs names the keys Shoes needs; map Qt's codes onto the same names the
// other backends report.
static const char *ext_key_name(int qt_key) {
  switch (qt_key) {
    case Qt::Key_Escape: return "escape";
    case Qt::Key_Insert: return "insert";
    case Qt::Key_Delete: return "delete";
    case Qt::Key_Home: return "home";
    case Qt::Key_End: return "end";
    case Qt::Key_PageUp: return "page_up";
    case Qt::Key_PageDown: return "page_down";
    case Qt::Key_Up: return "up";
    case Qt::Key_Down: return "down";
    case Qt::Key_Left: return "left";
    case Qt::Key_Right: return "right";
    case Qt::Key_F1: return "f1";
    case Qt::Key_F2: return "f2";
    case Qt::Key_F3: return "f3";
    case Qt::Key_F4: return "f4";
    case Qt::Key_F5: return "f5";
    case Qt::Key_F6: return "f6";
    case Qt::Key_F7: return "f7";
    case Qt::Key_F8: return "f8";
    case Qt::Key_F9: return "f9";
    case Qt::Key_F10: return "f10";
    case Qt::Key_F11: return "f11";
    case Qt::Key_F12: return "f12";
    default: return nullptr;
  }
}

static int modifier_bits(Qt::KeyboardModifiers m) {
  int bits = 0;
  if (m & Qt::ControlModifier) bits |= 1 << 0;
  if (m & Qt::AltModifier) bits |= 1 << 1;
  if (m & Qt::ShiftModifier) bits |= 1 << 2;
  if (m & Qt::MetaModifier) bits |= 1 << 3;
  return bits;
}

static int held_bits(Qt::MouseButtons b) {
  int bits = 0;
  if (b & Qt::LeftButton) bits |= 1;
  if (b & Qt::MiddleButton) bits |= 2;
  if (b & Qt::RightButton) bits |= 4;
  return bits;
}

static int button_number(Qt::MouseButton b) {
  if (b == Qt::LeftButton) return 1;
  if (b == Qt::MiddleButton) return 2;
  if (b == Qt::RightButton) return 3;
  return 0;
}

// ---- the canvas ---------------------------------------------------------

// Everything Clogs draws lives in one of these per window: it paints the whole
// Shoes document rather than assembling native controls, for the reason set
// out in docs/backends.md.
class ClogsCanvas : public QWidget {
public:
  ClogsCanvas(QWidget *parent) : QWidget(parent) {
    setMouseTracking(true);
    setFocusPolicy(Qt::StrongFocus);
    setAttribute(Qt::WA_OpaquePaintEvent);
  }

protected:
  void paintEvent(QPaintEvent *) override {
    if (!g_paint) return;
    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing, true);
    painter.setRenderHint(QPainter::TextAntialiasing, true);
    painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
    g_paint(this, &painter, width(), height());
  }

  void mouseMoveEvent(QMouseEvent *e) override { report(e, 0, 0); }
  void mousePressEvent(QMouseEvent *e) override { report(e, button_number(e->button()), 0); }
  void mouseReleaseEvent(QMouseEvent *e) override { report(e, 0, button_number(e->button())); }
  void enterEvent(QEnterEvent *) override { if (g_cross) g_cross(this, 0); }
  void leaveEvent(QEvent *) override { if (g_cross) g_cross(this, 1); }

  void keyPressEvent(QKeyEvent *e) override { key(e, 0); }
  void keyReleaseEvent(QKeyEvent *e) override { key(e, 1); }

private:
  void report(QMouseEvent *e, int down, int up) {
    if (!g_mouse) return;
    QPointF p = e->position();
    // Qt reports the buttons held *after* a press but *before* a release, so
    // on release the released button is added back: Clogs' hover tracking
    // wants "what was held when this happened".
    int held = held_bits(e->buttons());
    if (up) held |= (1 << (up - 1));
    g_mouse(this, p.x(), p.y(), down, up, held, modifier_bits(e->modifiers()));
  }

  void key(QKeyEvent *e, int up) {
    if (!g_key) { e->ignore(); return; }
    const char *ext = ext_key_name(e->key());
    // Qt hands over the text the keyboard layout actually produced, so there
    // is no shift table to maintain and non-US layouts report what was typed.
    QByteArray utf8 = e->text().toUtf8();
    const char *text = utf8.isEmpty() ? nullptr : utf8.constData();
    if (g_key(this, text, ext, modifier_bits(e->modifiers()), up)) {
      e->accept();
    } else {
      e->ignore();
    }
  }
};

class ClogsWindow : public QWidget {
public:
  ClogsWindow(const char *title, int w, int h) {
    setWindowTitle(QString::fromUtf8(title));
    resize(w, h);
    auto *layout = new QVBoxLayout(this);
    layout->setContentsMargins(0, 0, 0, 0);
    layout->setSpacing(0);
    canvas = new ClogsCanvas(this);
    layout->addWidget(canvas);
  }

  ClogsCanvas *canvas;

protected:
  void closeEvent(QCloseEvent *e) override {
    if (g_close) g_close(this);
    e->ignore(); // Clogs decides when the window really goes.
  }
};

// ---- application --------------------------------------------------------

// Qt's image loaders report libpng's opinion of a file through the log, and
// libpng has an opinion about half the PNGs on the internet ("iCCP: known
// incorrect sRGB profile") that has nothing to do with whether the image
// loaded. Clogs decides that for itself and says so in its own words, so this
// drops that one category and passes everything else through.
//
// A logging *rule* would be the tidier way and does not work: the message is
// emitted through a category whose rules QApplication resets, and setting
// QT_LOGGING_RULES does not silence it either.
static void clogs_message_handler(QtMsgType type, const QMessageLogContext &ctx,
                                  const QString &message) {
  if (ctx.category && std::strncmp(ctx.category, "qt.gui.imageio", 14) == 0) return;

  QByteArray text = message.toLocal8Bit();
  switch (type) {
    case QtDebugMsg: std::fprintf(stderr, "%s\n", text.constData()); break;
    case QtInfoMsg: std::fprintf(stderr, "%s\n", text.constData()); break;
    case QtWarningMsg: std::fprintf(stderr, "%s\n", text.constData()); break;
    case QtCriticalMsg: std::fprintf(stderr, "%s\n", text.constData()); break;
    case QtFatalMsg: std::fprintf(stderr, "%s\n", text.constData()); std::abort();
  }
}

static int g_argc = 1;
static char g_arg0[] = "clogs";
static char *g_argv[] = {g_arg0, nullptr};
static QApplication *g_app = nullptr;

int clogs_qt_init(void) {
  if (g_app) return 1;

  // Qt warns once on stderr when XDG_RUNTIME_DIR is unset, which it is on a
  // headless server and in most CI. It is a true statement about the
  // environment and nothing to do with the program, so give Qt somewhere to
  // put its runtime files rather than let every Shoes program on this backend
  // start by complaining.
  if (!qEnvironmentVariableIsSet("XDG_RUNTIME_DIR")) {
    QString dir = QString("/tmp/clogs-runtime-%1").arg(getuid());
    QDir().mkpath(dir);
    // Qt checks the mode as well as the path and complains at 0755.
    QFile::setPermissions(dir, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    qputenv("XDG_RUNTIME_DIR", dir.toUtf8());
  }

  qInstallMessageHandler(clogs_message_handler);
  g_app = new QApplication(g_argc, g_argv);
  return g_app != nullptr;
}

int clogs_qt_run(void) { return g_app ? g_app->exec() : -1; }

// Not QApplication::quit(). That one asks every window to close first, and
// Clogs' windows refuse a close they did not initiate -- the Shoes app decides
// when it is really going -- so quit() waits forever on a window that will
// never agree, and the X connection eventually drops underneath it. Ending the
// event loop directly is what was meant.
void clogs_qt_quit(void) { QCoreApplication::exit(0); }
void clogs_qt_process_events(void) { if (g_app) g_app->processEvents(); }

void *clogs_qt_window_new(const char *title, int w, int h) { return new ClogsWindow(title, w, h); }
void *clogs_qt_window_canvas(void *win) { return static_cast<ClogsWindow *>(win)->canvas; }
void clogs_qt_window_show(void *win) { static_cast<ClogsWindow *>(win)->show(); }

void clogs_qt_window_destroy(void *win) {
  auto *w = static_cast<ClogsWindow *>(win);
  w->hide();
  w->deleteLater();
}

void clogs_qt_canvas_update(void *canvas) { static_cast<ClogsCanvas *>(canvas)->update(); }

// ---- timers -------------------------------------------------------------

void *clogs_qt_timer_new(int ms, int repeat, int id) {
  QTimer *t = new QTimer();
  t->setSingleShot(!repeat);
  t->setInterval(ms < 1 ? 1 : ms);
  QObject::connect(t, &QTimer::timeout, [id]() { if (g_timer) g_timer(id); });
  t->start();
  return t;
}

void clogs_qt_timer_stop(void *timer) {
  QTimer *t = static_cast<QTimer *>(timer);
  if (!t) return;
  t->stop();
  t->deleteLater();
}

// ---- painting -----------------------------------------------------------

void clogs_qt_save(void *p) { static_cast<QPainter *>(p)->save(); }
void clogs_qt_restore(void *p) { static_cast<QPainter *>(p)->restore(); }
void clogs_qt_translate(void *p, double x, double y) { static_cast<QPainter *>(p)->translate(x, y); }
void clogs_qt_rotate(void *p, double degrees) { static_cast<QPainter *>(p)->rotate(degrees); }
void clogs_qt_scale(void *p, double sx, double sy) { static_cast<QPainter *>(p)->scale(sx, sy); }
void clogs_qt_shear(void *p, double sh, double sv) { static_cast<QPainter *>(p)->shear(sh, sv); }

void clogs_qt_clip_rect(void *p, double x, double y, double w, double h) {
  static_cast<QPainter *>(p)->setClipRect(QRectF(x, y, w, h), Qt::IntersectClip);
}

void clogs_qt_fill_rect(void *p, double x, double y, double w, double h, unsigned int rgba) {
  static_cast<QPainter *>(p)->fillRect(QRectF(x, y, w, h), rgba_color(rgba));
}

// A path arrives as one flat array of doubles rather than as a call per
// segment: crossing into C once per shape rather than once per point is what
// keeps this backend's per-frame cost in the same range as the others.
//
//   0 x y                     move to
//   1 x y                     line to
//   2 c1x c1y c2x c2y x y     cubic to
//   3 cx cy r start sweep     arc, continuing the current figure
//   4 x y w h                 rectangle
//   5 x y w h                 ellipse
//   6                         close subpath
//   7 cx cy r start sweep     arc, beginning a figure of its own
static QPainterPath build_path(const double *d, int len, int alternate) {
  QPainterPath path;
  path.setFillRule(alternate ? Qt::OddEvenFill : Qt::WindingFill);
  int i = 0;
  while (i < len) {
    int cmd = static_cast<int>(d[i++]);
    switch (cmd) {
      case 0: path.moveTo(d[i], d[i + 1]); i += 2; break;
      case 1:
        if (path.elementCount() == 0) path.moveTo(d[i], d[i + 1]);
        else path.lineTo(d[i], d[i + 1]);
        i += 2;
        break;
      case 2: path.cubicTo(d[i], d[i + 1], d[i + 2], d[i + 3], d[i + 4], d[i + 5]); i += 6; break;
      case 3:
      case 7: {
        double cx = d[i], cy = d[i + 1], r = d[i + 2], start = d[i + 3], sweep = d[i + 4];
        i += 5;
        QRectF box(cx - r, cy - r, 2 * r, 2 * r);
        // Clogs' angles follow libui: measured from the positive x axis and
        // increasing clockwise on screen. Qt measures counter-clockwise in
        // degrees, so both are negated.
        double start_deg = -start * 180.0 / M_PI;
        double sweep_deg = -sweep * 180.0 / M_PI;
        // libui distinguishes an arc that starts a figure from one that
        // continues the last, and Clogs' rounded rectangles rely on it: the
        // first corner opens the figure, the other three connect to it. Qt has
        // only arcTo, which draws a line from wherever the path currently is
        // -- so a figure-opening arc has to move there first, or the shape
        // grows a spike back to the origin.
        if (cmd == 7 || path.elementCount() == 0) {
          path.moveTo(cx + r * std::cos(start), cy + r * std::sin(start));
        }
        path.arcTo(box, start_deg, sweep_deg);
        break;
      }
      case 4: path.addRect(QRectF(d[i], d[i + 1], d[i + 2], d[i + 3])); i += 4; break;
      case 5: path.addEllipse(QRectF(d[i], d[i + 1], d[i + 2], d[i + 3])); i += 4; break;
      case 6: path.closeSubpath(); break;
      default: return path;
    }
  }
  return path;
}

void clogs_qt_fill_path(void *p, const double *d, int len, unsigned int rgba, int alternate) {
  QPainter *painter = static_cast<QPainter *>(p);
  painter->fillPath(build_path(d, len, alternate), rgba_color(rgba));
}

// `background red..blue` in Shoes: a vertical gradient over the shape's box.
void clogs_qt_fill_path_gradient(void *p, const double *d, int len, int alternate,
                                 double x1, double y1, double x2, double y2,
                                 unsigned int from, unsigned int to) {
  QPainter *painter = static_cast<QPainter *>(p);
  QLinearGradient g(x1, y1, x2, y2);
  g.setColorAt(0.0, rgba_color(from));
  g.setColorAt(1.0, rgba_color(to));
  painter->fillPath(build_path(d, len, alternate), QBrush(g));
}

void clogs_qt_stroke_path(void *p, const double *d, int len, unsigned int rgba, double width,
                          int cap, int join, const double *dashes, int dash_len) {
  QPainter *painter = static_cast<QPainter *>(p);
  QPen pen(rgba_color(rgba));
  pen.setWidthF(width <= 0 ? 1 : width);
  pen.setCapStyle(cap == 1 ? Qt::RoundCap : (cap == 2 ? Qt::SquareCap : Qt::FlatCap));
  pen.setJoinStyle(join == 1 ? Qt::RoundJoin : (join == 2 ? Qt::BevelJoin : Qt::MiterJoin));
  if (dashes && dash_len > 0) {
    QVector<qreal> pattern;
    for (int i = 0; i < dash_len; i++) pattern << (dashes[i] / (width <= 0 ? 1 : width));
    pen.setDashPattern(pattern);
  }
  painter->strokePath(build_path(d, len, 0), pen);
}

// ---- text ---------------------------------------------------------------

static QFont make_font(const char *family, double size, int bold, int italic,
                       int underline, int strike) {
  QFont f;
  if (family && *family) f.setFamily(QString::fromUtf8(family));
  f.setPointSizeF(size > 0 ? size : 12);
  f.setBold(bold != 0);
  f.setItalic(italic != 0);
  f.setUnderline(underline != 0);
  f.setStrikeOut(strike != 0);
  return f;
}

// Clogs places text by its top-left corner; Qt draws from the baseline.
void clogs_qt_draw_text(void *p, double x, double y, const char *utf8, const char *family,
                        double size, int bold, int italic, int underline, int strike,
                        unsigned int rgba) {
  QPainter *painter = static_cast<QPainter *>(p);
  QFont font = make_font(family, size, bold, italic, underline, strike);
  painter->setFont(font);
  painter->setPen(rgba_color(rgba));
  QFontMetricsF fm(font);
  painter->drawText(QPointF(x, y + fm.ascent()), QString::fromUtf8(utf8));
}

// Measuring needs no painter and no window, which is what lets Clogs lay text
// out during its own layout pass.
void clogs_qt_text_extent(const char *utf8, const char *family, double size, int bold, int italic,
                          double *out_w, double *out_h) {
  QFontMetricsF fm(make_font(family, size, bold, italic, 0, 0));
  QString s = QString::fromUtf8(utf8);
  *out_w = fm.horizontalAdvance(s);
  *out_h = fm.height();
}

// ---- images -------------------------------------------------------------

void *clogs_qt_image_load(const char *path) {
  QImage *img = new QImage();
  if (!img->load(QString::fromUtf8(path))) {
    delete img;
    return nullptr;
  }
  // Everything downstream composites, so normalise the format once here.
  QImage *converted = new QImage(img->convertToFormat(QImage::Format_ARGB32_Premultiplied));
  delete img;
  return converted;
}

void clogs_qt_image_size(void *image, int *w, int *h) {
  QImage *img = static_cast<QImage *>(image);
  *w = img->width();
  *h = img->height();
}

void *clogs_qt_image_scaled(void *image, int w, int h) {
  QImage *img = static_cast<QImage *>(image);
  return new QImage(img->scaled(w, h, Qt::IgnoreAspectRatio, Qt::SmoothTransformation));
}

void clogs_qt_image_free(void *image) { delete static_cast<QImage *>(image); }

void clogs_qt_draw_image(void *p, void *image, double x, double y, double w, double h) {
  QPainter *painter = static_cast<QPainter *>(p);
  QImage *img = static_cast<QImage *>(image);
  painter->drawImage(QRectF(x, y, w, h), *img);
}

// ---- dialogs ------------------------------------------------------------

// Returned strings live in a single buffer that the next call overwrites; the
// Ruby side copies immediately.
static std::string g_answer;

void clogs_qt_alert(void *win, const char *message) {
  QMessageBox::information(static_cast<QWidget *>(win), "Shoes", QString::fromUtf8(message));
}

int clogs_qt_confirm(void *win, const char *message) {
  return QMessageBox::question(static_cast<QWidget *>(win), "Shoes", QString::fromUtf8(message),
                               QMessageBox::Yes | QMessageBox::No) == QMessageBox::Yes;
}

const char *clogs_qt_ask(void *win, const char *message) {
  bool ok = false;
  QString text = QInputDialog::getText(static_cast<QWidget *>(win), "Shoes",
                                       QString::fromUtf8(message), QLineEdit::Normal,
                                       QString(), &ok);
  if (!ok) return nullptr;
  g_answer = text.toUtf8().constData();
  return g_answer.c_str();
}

const char *clogs_qt_ask_open_file(void *win) {
  QString path = QFileDialog::getOpenFileName(static_cast<QWidget *>(win), "Open File");
  if (path.isEmpty()) return nullptr;
  g_answer = path.toUtf8().constData();
  return g_answer.c_str();
}

const char *clogs_qt_ask_save_file(void *win) {
  QString path = QFileDialog::getSaveFileName(static_cast<QWidget *>(win), "Save File");
  if (path.isEmpty()) return nullptr;
  g_answer = path.toUtf8().constData();
  return g_answer.c_str();
}

const char *clogs_qt_ask_open_folder(void *win) {
  QString path = QFileDialog::getExistingDirectory(static_cast<QWidget *>(win), "Open Folder");
  if (path.isEmpty()) return nullptr;
  g_answer = path.toUtf8().constData();
  return g_answer.c_str();
}

const char *clogs_qt_version(void) { return qVersion(); }


} // extern "C"
