/*
 * Clogs' NAppGUI backend, C side.
 *
 * NAppGUI is a C SDK, so unlike the Qt backend this exists for two narrower
 * reasons rather than for want of a binding at all:
 *
 *   1. NAppGUI wants to own main(). Its `osmain` macro *defines* main() and
 *      hands control to the SDK, which a Ruby process cannot do -- Ruby owns
 *      main already. The macro expands to `osmain_imp`, which is an ordinary
 *      exported function, so this calls that directly.
 *
 *   2. Its events arrive as structs behind `event_params`, and its listeners
 *      are objects rather than plain function pointers. Unpacking those in C
 *      is a few lines; doing it from Fiddle would mean encoding NAppGUI's
 *      struct layouts in Ruby and re-encoding them at every release.
 *
 * Everything else is a straight pass-through to draw2d.
 *
 * Build with clogs/ext/nappgui/build.sh, or `rake nappgui:build`.
 */

#include <nappgui.h>
#include <osapp/osmain.h>
#include <osapp/osmain.hxx>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#if defined(__linux__)
/* NAppGUI's key event has no character in it; see the keyboard section. */
#include <gtk/gtk.h>
#endif

extern "C" {

/* ---- callbacks into Ruby ---------------------------------------------- */

typedef void (*CreateCb)(void);
typedef void (*PaintCb)(void *view, void *ctx, float width, float height);
typedef void (*MouseCb)(void *view, float x, float y, int down, int up, int held, int mods);
typedef int (*KeyCb)(void *view, int unicode, int keysym, int mods, int up);
typedef void (*CrossCb)(void *view, int left);
typedef void (*CloseCb)(void *window);
typedef void (*TimerCb)(int id);

static CreateCb g_create = NULL;
static PaintCb g_paint = NULL;
static MouseCb g_mouse = NULL;
static KeyCb g_key = NULL;
static CrossCb g_cross = NULL;
static CloseCb g_close = NULL;
static TimerCb g_timer = NULL;

void clogs_nap_on_create(CreateCb cb) { g_create = cb; }
void clogs_nap_on_paint(PaintCb cb) { g_paint = cb; }
void clogs_nap_on_mouse(MouseCb cb) { g_mouse = cb; }
void clogs_nap_on_key(KeyCb cb) { g_key = cb; }
void clogs_nap_on_crossed(CrossCb cb) { g_cross = cb; }
void clogs_nap_on_close(CloseCb cb) { g_close = cb; }
void clogs_nap_on_timer(TimerCb cb) { g_timer = cb; }

/* ---- timers ------------------------------------------------------------
 *
 * NAppGUI has no general timer. Its model for anything that moves is a single
 * update callback at a fixed frame rate, which is what `osmain_sync` sets up,
 * so Clogs' timers are scheduled against that one tick here rather than in
 * Ruby -- the Ruby side then looks like it does on every other backend.
 */

#define MAX_TIMERS 256

typedef struct {
    int id;
    int active;
    int repeat;
    double interval; /* seconds */
    double next;     /* seconds, on the same clock as the update callback */
} clogs_timer_t;

static clogs_timer_t g_timers[MAX_TIMERS];
static double g_now = 0.;

void clogs_nap_timer_new(int ms, int repeat, int id)
{
    int i;
    double interval = (ms < 1 ? 1 : ms) / 1000.;
    for (i = 0; i < MAX_TIMERS; i++)
    {
        if (g_timers[i].active == 0)
        {
            g_timers[i].id = id;
            g_timers[i].active = 1;
            g_timers[i].repeat = repeat;
            g_timers[i].interval = interval;
            g_timers[i].next = g_now + interval;
            return;
        }
    }
}

void clogs_nap_timer_stop(int id)
{
    int i;
    for (i = 0; i < MAX_TIMERS; i++)
    {
        if (g_timers[i].active && g_timers[i].id == id)
            g_timers[i].active = 0;
    }
}

/* ---- application ------------------------------------------------------- */

static void i_tick(void *app, const real64_t prtime, const real64_t ctime)
{
    int i;
    unref(app);
    unref(prtime);
    g_now = (double)ctime;
    for (i = 0; i < MAX_TIMERS; i++)
    {
        if (g_timers[i].active == 0 || g_timers[i].next > g_now)
            continue;

        if (g_timers[i].repeat)
        {
            g_timers[i].next = g_now + g_timers[i].interval;
        }
        else
        {
            g_timers[i].active = 0;
        }

        if (g_timer != NULL)
            g_timer(g_timers[i].id);
    }
}

/* Set once osmain_imp has started the SDK. draw2d is not up before that, so
 * nothing may create a font, a window or an image until it is true -- which is
 * the one thing this backend forces on the Ruby side that no other does. */
static int g_started = 0;

int clogs_nap_started(void) { return g_started; }

static void *i_create(void)
{
    g_started = 1;
    /* gui_start() opened a log file under the user's config directory before
     * this ran; nothing wants a Shoes program writing there. */
    log_file(NULL);
    /* The window is built on the Ruby side, once the SDK is up. */
    if (g_create != NULL)
        g_create();
    return (void *)1;
}

static void i_destroy(void **app)
{
    unref(app);
}

/* The frame rate the timer tick runs at. Clogs' own timers are scheduled
 * against it, so it has to be at least as fine as the fastest `animate`. */
static real64_t g_frame = 1. / 120.;

int clogs_nap_run(void)
{
    static char arg0[] = "clogs";
    static char *argv[] = {arg0, NULL};

    /* NAppGUI logs to stdout by default and prints a heap audit on the way
     * out. Both are the SDK talking about itself, and a Shoes program's own
     * output is the only thing that should come out of a Shoes program --
     * Clogs' own suites read anything else as a failure. CLOGS_NAP_LOG=1
     * puts it back when the SDK is what is being debugged. */
    if (getenv("CLOGS_NAP_LOG") == NULL)
        log_output(FALSE, FALSE);

    osmain_imp(1, (char_t **)argv, NULL, g_frame,
               (FPtr_app_create)i_create,
               (FPtr_app_update)i_tick,
               (FPtr_destroy)i_destroy,
               (char_t *)"");
    return 0;
}

void clogs_nap_quit(void) { osapp_finish(); }

/* ---- window and view --------------------------------------------------- */

static void i_OnDraw(void *data, Event *e)
{
    const EvDraw *p = event_params(e, EvDraw);
    unref(data);
    if (g_paint != NULL)
        g_paint(event_sender_imp(e, NULL), p->ctx, p->width, p->height);
}

static int i_modifiers(const uint32_t mods)
{
    int bits = 0;
    if ((mods & ekMKEY_CONTROL) != 0)
        bits |= 1 << 0;
    if ((mods & ekMKEY_ALT) != 0)
        bits |= 1 << 1;
    if ((mods & ekMKEY_SHIFT) != 0)
        bits |= 1 << 2;
    return bits;
}

static int i_button(const gui_mouse_t button)
{
    switch (button)
    {
    case ekGUI_MOUSE_LEFT:
        return 1;
    case ekGUI_MOUSE_MIDDLE:
        return 2;
    case ekGUI_MOUSE_RIGHT:
        return 3;
    default:
        return 0;
    }
}

/* NAppGUI reports which button an event concerns but not which are held, so
 * the held set is tracked from the presses and releases as they arrive --
 * Clogs' hover tracking asks for it on every move. */
static int g_held = 0;

static void i_OnMove(void *data, Event *e)
{
    const EvMouse *p = event_params(e, EvMouse);
    unref(data);
    if (g_mouse != NULL)
        g_mouse(event_sender_imp(e, NULL), p->x, p->y, 0, 0, g_held, i_modifiers(p->modifiers));
}

static void i_OnDown(void *data, Event *e)
{
    const EvMouse *p = event_params(e, EvMouse);
    int button = i_button(p->button);
    unref(data);
    if (button > 0)
        g_held |= (1 << (button - 1));
    if (g_mouse != NULL)
        g_mouse(event_sender_imp(e, NULL), p->x, p->y, button, 0, g_held, i_modifiers(p->modifiers));
}

static void i_OnUp(void *data, Event *e)
{
    const EvMouse *p = event_params(e, EvMouse);
    int button = i_button(p->button);
    int held = g_held;
    unref(data);
    if (button > 0)
        g_held &= ~(1 << (button - 1));
    if (g_mouse != NULL)
        g_mouse(event_sender_imp(e, NULL), p->x, p->y, 0, button, held, i_modifiers(p->modifiers));
}

static void i_OnEnter(void *data, Event *e)
{
    unref(data);
    if (g_cross != NULL)
        g_cross(event_sender_imp(e, NULL), 0);
}

static void i_OnExit(void *data, Event *e)
{
    unref(data);
    if (g_cross != NULL)
        g_cross(event_sender_imp(e, NULL), 1);
}

/* ---- keyboard ----------------------------------------------------------
 *
 * NAppGUI's key event carries a vkey_t and nothing else. There is no
 * character in it and no way to ask for one, and the vkey table is a fixed
 * list of GDK keysyms built around a Spanish keyboard: a US-layout `=`, `[`,
 * `]`, `/`, `\` or backtick maps to no vkey at all. A text editor -- which is
 * the whole of Hackety Hack -- cannot be written on that.
 *
 * So on GTK the shim reaches past NAppGUI and reads the keysym itself, which
 * is where the layout has already been applied. The vkey path below stays as
 * the portable fallback for the platforms this shim has not been built on --
 * where it will lose the same keys, for want of anywhere else to get them.
 */

/* Set once a GTK hook is in place for a view; the vkey handlers then stand
 * down rather than reporting the same keystroke a second time. */
static int g_native_keys = 0;

static void i_OnKeyDown(void *data, Event *e)
{
    const EvKey *p = event_params(e, EvKey);
    unref(data);
    if (g_native_keys == 0 && g_key != NULL)
        g_key(event_sender_imp(e, NULL), 0, (int)p->key, i_modifiers(p->modifiers), 0);
}

static void i_OnKeyUp(void *data, Event *e)
{
    const EvKey *p = event_params(e, EvKey);
    unref(data);
    if (g_native_keys == 0 && g_key != NULL)
        g_key(event_sender_imp(e, NULL), 0, (int)p->key, i_modifiers(p->modifiers), 1);
}

#if defined(__linux__)

static gboolean i_gtk_key(GtkWidget *widget, GdkEventKey *event, gpointer view)
{
    int mods = 0;
    int up = (event->type == GDK_KEY_RELEASE) ? 1 : 0;
    guint32 unicode = gdk_keyval_to_unicode(event->keyval);
    unref(widget);

    if ((event->state & GDK_CONTROL_MASK) != 0)
        mods |= 1 << 0;
    if ((event->state & GDK_MOD1_MASK) != 0)
        mods |= 1 << 1;
    if ((event->state & GDK_SHIFT_MASK) != 0)
        mods |= 1 << 2;
    if ((event->state & GDK_SUPER_MASK) != 0)
        mods |= 1 << 3;

    if (g_key == NULL)
        return FALSE;

    /* Returning TRUE stops GTK routing the key on to the focused widget,
     * which is what a handled keystroke should do. */
    return g_key(view, (int)unicode, (int)event->keyval, mods, up) ? TRUE : FALSE;
}

/* A key snooper rather than a handler on the window, because NAppGUI's own
 * window handler runs first -- it is connected when the window is created,
 * before this shim has anything to connect to -- and it takes Tab, Return and
 * Escape for focus cycling and returns without passing them on. A snooper
 * sees every key before delivery, which is the only way to get those three.
 *
 * gtk_key_snooper_install is deprecated in GTK 3 and still works; there is no
 * replacement that runs earlier than a window's own handlers. */
static void *i_view_for_toplevel(GtkWidget *widget);

static gint i_snoop(GtkWidget *widget, GdkEventKey *event, gpointer data)
{
    void *view = i_view_for_toplevel(widget);
    unref(data);
    /* Not one of Clogs' windows -- a modal dialog's own text field, say.
     * Letting it through is the whole point of answering FALSE. */
    if (view == NULL)
        return FALSE;

    return i_gtk_key(widget, event, view) ? TRUE : FALSE;
}

static void i_hook_keys(void *window, void *view)
{
    unref(window);
    unref(view);
    if (g_native_keys == 0)
    {
        gtk_key_snooper_install(i_snoop, NULL);
        g_native_keys = 1;
    }
}

#else

static void i_hook_keys(void *window, void *view)
{
    unref(window);
    unref(view);
}

#endif

static void i_OnClose(void *data, Event *e)
{
    unref(data);
    if (g_close != NULL)
        g_close(event_sender_imp(e, NULL));
    /* Refuse the close: Clogs decides when the window really goes. */
    {
        bool_t *r = event_result(e, bool_t);
        if (r != NULL)
            *r = FALSE;
    }
}

/* NAppGUI offers no accessor from a window to the view inside it, so the
 * association is kept here. One view per window, one window per Clogs app. */
#define MAX_WINDOWS 64
static Window *g_windows[MAX_WINDOWS];
static View *g_views[MAX_WINDOWS];
static int g_window_count = 0;

static void clogs_nap_register(void *window, void *view)
{
    if (g_window_count < MAX_WINDOWS)
    {
        g_windows[g_window_count] = (Window *)window;
        g_views[g_window_count] = (View *)view;
        g_window_count++;
    }
}

/* Must happen before the window is destroyed: the key snooper walks this
 * table and asks each view for its native widget, which a destroyed view no
 * longer has. */
static void clogs_nap_unregister(void *window)
{
    int i;
    for (i = 0; i < g_window_count; i++)
    {
        if (g_windows[i] != (Window *)window)
            continue;

        g_window_count--;
        g_windows[i] = g_windows[g_window_count];
        g_views[i] = g_views[g_window_count];
        return;
    }
}

void *clogs_nap_window_new(const char *title, int width, int height)
{
    Window *window = window_create(ekWINDOW_STD);
    Panel *panel = panel_create();
    Layout *layout = layout_create(1, 1);
    View *view = view_create();

    view_size(view, s2df((real32_t)width, (real32_t)height));
    view_OnDraw(view, listener_imp(NULL, i_OnDraw));
    view_OnMove(view, listener_imp(NULL, i_OnMove));
    view_OnDown(view, listener_imp(NULL, i_OnDown));
    view_OnUp(view, listener_imp(NULL, i_OnUp));
    view_OnEnter(view, listener_imp(NULL, i_OnEnter));
    view_OnExit(view, listener_imp(NULL, i_OnExit));
    view_OnKeyDown(view, listener_imp(NULL, i_OnKeyDown));
    view_OnKeyUp(view, listener_imp(NULL, i_OnKeyUp));
    /* A window keeps Tab for itself to cycle focus between its controls.
     * Clogs' window holds exactly one control and its editor wants Tab, so
     * the view claims it. On GTK the key snooper below gets there first
     * anyway; this is what the other platforms have. */
    view_allow_tab(view, TRUE);

    layout_view(layout, view, 0, 0);
    panel_layout(panel, layout);
    window_panel(window, panel);
    window_title(window, (const char_t *)title);
    window_OnClose(window, listener_imp(NULL, i_OnClose));

    /* The view is what events arrive from and what gets redrawn, and the Ruby
     * side needs both, so the pair is remembered here. */
    clogs_nap_register(window, view);
    return window;
}

#if defined(__linux__)

/* Which Clogs view, if any, a key event delivered to `widget` belongs to. */
static void *i_view_for_toplevel(GtkWidget *widget)
{
    GtkWidget *toplevel = (widget != NULL) ? gtk_widget_get_toplevel(widget) : NULL;
    int i;
    if (toplevel == NULL)
        return NULL;

    for (i = 0; i < g_window_count; i++)
    {
        GtkWidget *native = (GtkWidget *)view_native(g_views[i]);
        if (native != NULL && gtk_widget_get_toplevel(native) == toplevel)
            return g_views[i];
    }
    return NULL;
}

#endif

void *clogs_nap_window_view(void *window)
{
    int i;
    for (i = 0; i < g_window_count; i++)
    {
        if (g_windows[i] == (Window *)window)
            return g_views[i];
    }
    return NULL;
}

void clogs_nap_window_show(void *window)
{
    window_show((Window *)window);
    i_hook_keys(window, clogs_nap_window_view(window));
}

void clogs_nap_window_destroy(void *window)
{
    Window *w = (Window *)window;
    clogs_nap_unregister(window);
    window_hide(w);
    window_destroy(&w);
}

void clogs_nap_view_update(void *view) { view_update((View *)view); }

/* ---- painting ---------------------------------------------------------- */

static color_t i_color(unsigned int rgba)
{
    return color_rgba((uint8_t)((rgba >> 24) & 0xff), (uint8_t)((rgba >> 16) & 0xff),
                      (uint8_t)((rgba >> 8) & 0xff), (uint8_t)(rgba & 0xff));
}

void clogs_nap_clear(void *ctx, unsigned int rgba)
{
    draw_clear((DCtx *)ctx, i_color(rgba));
}

/* ---- offscreen surfaces ------------------------------------------------
 *
 * draw2d has no clipping of any kind -- no rectangle, no region, no path. It
 * does have offscreen bitmap contexts, and a bitmap has edges, so a clip is
 * done by drawing into one the size of the clip rectangle and blitting the
 * result back. That is what the painter's clip_rect uses.
 */

void *clogs_nap_ctx_bitmap(int width, int height)
{
    DCtx *ctx = dctx_bitmap((uint32_t)(width < 1 ? 1 : width),
                            (uint32_t)(height < 1 ? 1 : height), ekRGBA32);
    if (ctx != NULL)
    {
        /* Transparent, so only what is drawn into it composites back. */
        draw_clear(ctx, color_rgba(0, 0, 0, 0));
        draw_antialias(ctx, TRUE);
    }
    return ctx;
}

/* Consumes the context and hands back the bitmap it drew. */
void *clogs_nap_ctx_to_image(void *ctx)
{
    DCtx *c = (DCtx *)ctx;
    return dctx_image(&c);
}

void clogs_nap_antialias(void *ctx, int on)
{
    draw_antialias((DCtx *)ctx, on ? TRUE : FALSE);
}

/* draw2d's transform is absolute rather than a stack, which suits Clogs: its
 * painters already keep the current matrix in Ruby, so the whole matrix is
 * handed over each time it changes. */
void clogs_nap_matrix(void *ctx, float a, float b, float c, float d, float e, float f)
{
    T2Df t2d;
    t2d.i.x = a;
    t2d.i.y = b;
    t2d.j.x = c;
    t2d.j.y = d;
    t2d.p.x = e;
    t2d.p.y = f;
    draw_matrixf((DCtx *)ctx, &t2d);
}

void clogs_nap_fill_color(void *ctx, unsigned int rgba)
{
    draw_fill_color((DCtx *)ctx, i_color(rgba));
}

void clogs_nap_fill_linear(void *ctx, unsigned int from, unsigned int to,
                           float x0, float y0, float x1, float y1)
{
    color_t colors[2];
    real32_t stops[2];
    colors[0] = i_color(from);
    colors[1] = i_color(to);
    stops[0] = 0.f;
    stops[1] = 1.f;
    draw_fill_linear((DCtx *)ctx, colors, stops, 2, x0, y0, x1, y1);
}

void clogs_nap_line_style(void *ctx, unsigned int rgba, float width, int cap, int join,
                          const float *dashes, int dash_count)
{
    DCtx *c = (DCtx *)ctx;
    draw_line_color(c, i_color(rgba));
    draw_line_width(c, width <= 0.f ? 1.f : width);
    draw_line_cap(c, cap == 1 ? ekLCROUND : (cap == 2 ? ekLCSQUARE : ekLCFLAT));
    draw_line_join(c, join == 1 ? ekLJROUND : (join == 2 ? ekLJBEVEL : ekLJMITER));
    if (dashes != NULL && dash_count > 0)
        draw_line_dash(c, (const real32_t *)dashes, (uint32_t)dash_count);
    else
        draw_line_dash(c, NULL, 0);
}

void clogs_nap_rect(void *ctx, int op, float x, float y, float w, float h)
{
    draw_rect((DCtx *)ctx, (drawop_t)op, x, y, w, h);
}

void clogs_nap_ellipse(void *ctx, int op, float cx, float cy, float rx, float ry)
{
    draw_ellipse((DCtx *)ctx, (drawop_t)op, cx, cy, rx, ry);
}

void clogs_nap_line(void *ctx, float x0, float y0, float x1, float y1)
{
    draw_line((DCtx *)ctx, x0, y0, x1, y1);
}

/* Points arrive as one flat array of floats, so a polygon costs one call
 * whatever its size. draw2d has no path object, so Clogs flattens curves and
 * arcs to points on the Ruby side and everything arrives here as a polygon. */
void clogs_nap_polygon(void *ctx, int op, const float *points, int count)
{
    draw_polygon((DCtx *)ctx, (drawop_t)op, (const V2Df *)points, (uint32_t)count);
}

void clogs_nap_polyline(void *ctx, int closed, const float *points, int count)
{
    draw_polyline((DCtx *)ctx, closed ? TRUE : FALSE, (const V2Df *)points, (uint32_t)count);
}

/* ---- text -------------------------------------------------------------- */

/* NAppGUI carries underline and strikethrough as font styles rather than as
 * text attributes, so `del()` and `ins()` render here without the painter
 * having to draw the line itself -- which is more than libui manages. Sizes
 * are asked for in points, to match what every other backend means by 14. */
void *clogs_nap_font(const char *family, float size, int bold, int italic,
                     int underline, int strike)
{
    uint32_t style = ekFPOINTS;
    if (bold != 0)
        style |= ekFBOLD;
    if (italic != 0)
        style |= ekFITALIC;
    if (underline != 0)
        style |= ekFUNDERLINE;
    if (strike != 0)
        style |= ekFSTRIKEOUT;
    return font_create((const char_t *)family, size, style);
}

void clogs_nap_font_destroy(void *font)
{
    Font *f = (Font *)font;
    font_destroy(&f);
}

void clogs_nap_font_extents(void *font, const char *text, float *width, float *height)
{
    font_extents((const Font *)font, (const char_t *)text, -1.f, (real32_t *)width, (real32_t *)height);
}

void clogs_nap_draw_text(void *ctx, void *font, const char *text, float x, float y,
                         unsigned int rgba)
{
    DCtx *c = (DCtx *)ctx;
    draw_font(c, (const Font *)font);
    draw_text_color(c, i_color(rgba));
    draw_text(c, (const char_t *)text, x, y);
}

/* ---- images ------------------------------------------------------------ */

void *clogs_nap_image_load(const char *path)
{
    ferror_t error;
    Image *image = image_from_file((const char_t *)path, &error);
    return (error == ekFOK) ? image : NULL;
}

void clogs_nap_image_size(void *image, int *width, int *height)
{
    *width = (int)image_width((const Image *)image);
    *height = (int)image_height((const Image *)image);
}

void *clogs_nap_image_scaled(void *image, int width, int height)
{
    return image_scale((const Image *)image, (uint32_t)width, (uint32_t)height);
}

void clogs_nap_image_free(void *image)
{
    Image *i = (Image *)image;
    image_destroy(&i);
}

void clogs_nap_draw_image(void *ctx, void *image, float x, float y)
{
    draw_image((DCtx *)ctx, (const Image *)image, x, y);
}

/* ---- dialogs -----------------------------------------------------------
 *
 * NAppGUI has file and colour pickers but no message box: `alert`, `confirm`
 * and `ask` are a window, a label and a button or two, which is what its own
 * examples build by hand. So they are built here.
 */

static char g_answer[4096];

/* Both handlers run inside window_modal's nested loop, so one dialog's state
 * is only ever live at a time; the previous values are kept across a nested
 * dialog (an `ask` from inside an `alert`'s handler) all the same. */
static Window *g_modal_window = NULL;
static Edit *g_modal_edit = NULL;

static void i_OnAccept(void *data, Event *e)
{
    unref(data);
    unref(e);
    if (g_modal_edit != NULL)
    {
        const char_t *text = edit_get_text(g_modal_edit);
        if (text != NULL)
        {
            strncpy(g_answer, (const char *)text, sizeof(g_answer) - 1);
            g_answer[sizeof(g_answer) - 1] = '\0';
        }
    }
    window_stop_modal(g_modal_window, 1);
}

static void i_OnReject(void *data, Event *e)
{
    unref(data);
    unref(e);
    window_stop_modal(g_modal_window, 0);
}

static void i_OnModalClose(void *data, Event *e)
{
    unref(data);
    unref(e);
    /* window_stop_modal is what ends the nested loop; the close itself has to
     * be allowed through or the dialog cannot be dismissed by its title bar. */
    window_stop_modal(g_modal_window, 0);
}

/* buttons: 1 for a lone OK, 2 for OK and Cancel. `initial` non-NULL adds a
 * text field and makes the answer readable from g_answer. */
static uint32_t i_modal(void *parent, const char *message, int buttons, const char *initial)
{
    Window *saved_window = g_modal_window;
    Edit *saved_edit = g_modal_edit;
    Window *window = window_create(ekWINDOW_TITLE | ekWINDOW_CLOSE);
    Panel *panel = panel_create();
    Layout *layout = layout_create(1, initial != NULL ? 3 : 2);
    Layout *buttons_layout = layout_create(buttons, 1);
    Label *label = label_create();
    Button *ok = button_push();
    uint32_t row = 0;
    uint32_t result = 0;

    label_multiline(label, TRUE);
    label_text(label, (const char_t *)message);
    layout_label(layout, label, 0, row++);

    if (initial != NULL)
    {
        Edit *edit = edit_create();
        edit_text(edit, (const char_t *)initial);
        edit_autoselect(edit, TRUE);
        layout_edit(layout, edit, 0, row++);
        g_modal_edit = edit;
    }
    else
    {
        g_modal_edit = NULL;
    }

    button_text(ok, (const char_t *)"OK");
    button_OnClick(ok, listener_imp(NULL, i_OnAccept));
    if (buttons > 1)
    {
        Button *cancel = button_push();
        button_text(cancel, (const char_t *)"Cancel");
        button_OnClick(cancel, listener_imp(NULL, i_OnReject));
        layout_button(buttons_layout, cancel, 0, 0);
        layout_button(buttons_layout, ok, 1, 0);
        layout_hmargin(buttons_layout, 0, 8.f);
    }
    else
    {
        layout_button(buttons_layout, ok, 0, 0);
    }
    layout_layout(layout, buttons_layout, 0, row);
    layout_halign(layout, 0, row, ekRIGHT);
    layout_hsize(layout, 0, 320.f);
    layout_margin(layout, 12.f);
    layout_vmargin(layout, 0, 10.f);
    if (initial != NULL)
        layout_vmargin(layout, 1, 10.f);

    panel_layout(panel, layout);
    window_panel(window, panel);
    window_title(window, (const char_t *)"Shoes");
    window_OnClose(window, listener_imp(NULL, i_OnModalClose));

    g_modal_window = window;
    result = window_modal(window, (Window *)parent);
    window_destroy(&window);
    g_modal_window = saved_window;
    g_modal_edit = saved_edit;
    return result;
}

void clogs_nap_alert(void *window, const char *message)
{
    i_modal(window, message, 1, NULL);
}

int clogs_nap_confirm(void *window, const char *message)
{
    return (int)i_modal(window, message, 2, NULL);
}

const char *clogs_nap_ask(void *window, const char *message)
{
    g_answer[0] = '\0';
    if (i_modal(window, message, 2, "") == 0)
        return NULL;
    return g_answer;
}

const char *clogs_nap_ask_open_file(void *window)
{
    return (const char *)comwin_open_file((Window *)window, NULL, NULL, 0, NULL, NULL);
}

const char *clogs_nap_ask_save_file(void *window)
{
    return (const char *)comwin_save_file((Window *)window, NULL, NULL, 0, NULL, NULL);
}

const char *clogs_nap_ask_open_folder(void *window)
{
    return (const char *)comwin_select_dir((Window *)window, NULL, NULL);
}

const char *clogs_nap_version(void) { return "NAppGUI"; }

} /* extern "C" */
