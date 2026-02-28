pub const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/extensions/Xinerama.h");
    @cInclude("X11/Xft/Xft.h");
});

pub const Display = c.Display;
pub const Window = c.Window;
pub const XEvent = c.XEvent;
pub const XWindowAttributes = c.XWindowAttributes;
pub const XWindowChanges = c.XWindowChanges;
pub const XMapRequestEvent = c.XMapRequestEvent;
pub const XConfigureRequestEvent = c.XConfigureRequestEvent;
pub const XKeyEvent = c.XKeyEvent;
pub const XDestroyWindowEvent = c.XDestroyWindowEvent;
pub const XUnmapEvent = c.XUnmapEvent;
pub const XCrossingEvent = c.XCrossingEvent;
pub const XFocusChangeEvent = c.XFocusChangeEvent;
pub const XErrorEvent = c.XErrorEvent;
pub const KeySym = c.KeySym;

pub const XOpenDisplay = c.XOpenDisplay;
pub const XCloseDisplay = c.XCloseDisplay;
pub const XConnectionNumber = c.XConnectionNumber;
pub const XDefaultScreen = c.XDefaultScreen;
pub const XRootWindow = c.XRootWindow;
pub const XDisplayWidth = c.XDisplayWidth;
pub const XDisplayHeight = c.XDisplayHeight;
pub const XNextEvent = c.XNextEvent;
pub const XPending = c.XPending;
pub const XSync = c.XSync;
pub const XSelectInput = c.XSelectInput;
pub const XSetErrorHandler = c.XSetErrorHandler;
pub const XGrabKey = c.XGrabKey;
pub const XKeysymToKeycode = c.XKeysymToKeycode;
pub const XKeycodeToKeysym = c.XKeycodeToKeysym;
pub const XQueryTree = c.XQueryTree;
pub const XFree = c.XFree;
pub const XGetWindowAttributes = c.XGetWindowAttributes;
pub const XMapWindow = c.XMapWindow;
pub const XConfigureWindow = c.XConfigureWindow;
pub const XSetInputFocus = c.XSetInputFocus;
pub const XRaiseWindow = c.XRaiseWindow;
pub const XMoveResizeWindow = c.XMoveResizeWindow;
pub const XMoveWindow = c.XMoveWindow;
pub const XSetWindowBorder = c.XSetWindowBorder;
pub const XSetWindowBorderWidth = c.XSetWindowBorderWidth;

pub const SubstructureRedirectMask = c.SubstructureRedirectMask;
pub const SubstructureNotifyMask = c.SubstructureNotifyMask;
pub const EnterWindowMask = c.EnterWindowMask;
pub const FocusChangeMask = c.FocusChangeMask;
pub const PropertyChangeMask = c.PropertyChangeMask;
pub const StructureNotifyMask = c.StructureNotifyMask;

pub const Mod4Mask = c.Mod4Mask;
pub const ShiftMask = c.ShiftMask;
pub const LockMask = c.LockMask;
pub const Mod2Mask = c.Mod2Mask;
pub const ControlMask = c.ControlMask;

pub const GrabModeAsync = c.GrabModeAsync;
pub const RevertToPointerRoot = c.RevertToPointerRoot;
pub const CurrentTime = c.CurrentTime;
pub const NotifyNormal = c.NotifyNormal;
pub const NotifyInferior = c.NotifyInferior;

pub const True = c.True;
pub const False = c.False;

pub const XK_q = c.XK_q;
pub const XK_f = c.XK_f;
pub const XK_h = c.XK_h;
pub const XK_i = c.XK_i;
pub const XK_d = c.XK_d;
pub const XK_j = c.XK_j;
pub const XK_k = c.XK_k;
pub const XK_l = c.XK_l;
pub const XK_m = c.XK_m;
pub const XK_comma = c.XK_comma;
pub const XK_period = c.XK_period;
pub const XK_space = c.XK_space;
pub const XK_Return = c.XK_Return;
pub const XK_p = c.XK_p;
pub const XK_a = c.XK_a;
pub const XK_s = c.XK_s;
pub const XK_1 = c.XK_1;
pub const XK_2 = c.XK_2;
pub const XK_3 = c.XK_3;
pub const XK_4 = c.XK_4;
pub const XK_5 = c.XK_5;
pub const XK_6 = c.XK_6;
pub const XK_7 = c.XK_7;
pub const XK_8 = c.XK_8;
pub const XK_9 = c.XK_9;

pub const Mod1Mask = c.Mod1Mask;
pub const Mod3Mask = c.Mod3Mask;
pub const Mod5Mask = c.Mod5Mask;

pub const XKillClient = c.XKillClient;
pub const XInternAtom = c.XInternAtom;
pub const XChangeProperty = c.XChangeProperty;
pub const XGetWindowProperty = c.XGetWindowProperty;
pub const XSendEvent = c.XSendEvent;

pub const Atom = c.Atom;
pub const XA_ATOM = c.XA_ATOM;
pub const XClientMessageEvent = c.XClientMessageEvent;

pub const PropModeReplace = c.PropModeReplace;

pub const XGrabPointer = c.XGrabPointer;
pub const XUngrabPointer = c.XUngrabPointer;
pub const XGrabButton = c.XGrabButton;
pub const XQueryPointer = c.XQueryPointer;
pub const XWarpPointer = c.XWarpPointer;
pub const XGetModifierMapping = c.XGetModifierMapping;
pub const XFreeModifiermap = c.XFreeModifiermap;
pub const XModifierKeymap = c.XModifierKeymap;
pub const XK_Num_Lock = c.XK_Num_Lock;

pub const Button1 = c.Button1;
pub const Button1Mask = c.Button1Mask;
pub const Button3 = c.Button3;
pub const Button3Mask = c.Button3Mask;
pub const ButtonPressMask = c.ButtonPressMask;
pub const ButtonReleaseMask = c.ButtonReleaseMask;
pub const PointerMotionMask = c.PointerMotionMask;
pub const GrabModeSync = c.GrabModeSync;
pub const GrabSuccess = c.GrabSuccess;
pub const None = c.None;

pub const XButtonEvent = c.XButtonEvent;
pub const XMotionEvent = c.XMotionEvent;
pub const XExposeEvent = c.XExposeEvent;

pub const XineramaIsActive = c.XineramaIsActive;
pub const XineramaQueryScreens = c.XineramaQueryScreens;
pub const XineramaScreenInfo = c.XineramaScreenInfo;

pub const XftFont = c.XftFont;
pub const XftColor = c.XftColor;
pub const XftDraw = c.XftDraw;
pub const XftFontOpenName = c.XftFontOpenName;
pub const XftFontClose = c.XftFontClose;
pub const XftDrawCreate = c.XftDrawCreate;
pub const XftDrawDestroy = c.XftDrawDestroy;
pub const XftDrawStringUtf8 = c.XftDrawStringUtf8;
pub const XftColorAllocValue = c.XftColorAllocValue;
pub const XftColorFree = c.XftColorFree;
pub const XftTextExtentsUtf8 = c.XftTextExtentsUtf8;
pub const XGlyphInfo = c.XGlyphInfo;
pub const XRenderColor = c.XRenderColor;

pub const XCreatePixmap = c.XCreatePixmap;
pub const XFreePixmap = c.XFreePixmap;
pub const XCopyArea = c.XCopyArea;
pub const XCreateGC = c.XCreateGC;
pub const XFreeGC = c.XFreeGC;
pub const XSetForeground = c.XSetForeground;
pub const XFillRectangle = c.XFillRectangle;
pub const XDefaultVisual = c.XDefaultVisual;
pub const XDefaultColormap = c.XDefaultColormap;
pub const XDefaultDepth = c.XDefaultDepth;
pub const Pixmap = c.Pixmap;
pub const Drawable = c.Drawable;
pub const GC = c.GC;
pub const Visual = c.Visual;
pub const Colormap = c.Colormap;

pub const KeyPress = c.KeyPress;
pub const KeyRelease = c.KeyRelease;
pub const ButtonPress = c.ButtonPress;
pub const ButtonRelease = c.ButtonRelease;
pub const MotionNotify = c.MotionNotify;
pub const EnterNotify = c.EnterNotify;
pub const LeaveNotify = c.LeaveNotify;
pub const FocusIn = c.FocusIn;
pub const FocusOut = c.FocusOut;
pub const KeymapNotify = c.KeymapNotify;
pub const Expose = c.Expose;
pub const GraphicsExpose = c.GraphicsExpose;
pub const NoExpose = c.NoExpose;
pub const VisibilityNotify = c.VisibilityNotify;
pub const CreateNotify = c.CreateNotify;
pub const DestroyNotify = c.DestroyNotify;
pub const UnmapNotify = c.UnmapNotify;
pub const MapNotify = c.MapNotify;
pub const MapRequest = c.MapRequest;
pub const ReparentNotify = c.ReparentNotify;
pub const ConfigureNotify = c.ConfigureNotify;
pub const ConfigureRequest = c.ConfigureRequest;
pub const GravityNotify = c.GravityNotify;
pub const ResizeRequest = c.ResizeRequest;
pub const CirculateNotify = c.CirculateNotify;
pub const CirculateRequest = c.CirculateRequest;
pub const PropertyNotify = c.PropertyNotify;
pub const SelectionClear = c.SelectionClear;
pub const SelectionRequest = c.SelectionRequest;
pub const SelectionNotify = c.SelectionNotify;
pub const ColormapNotify = c.ColormapNotify;
pub const ClientMessage = c.ClientMessage;
pub const MappingNotify = c.MappingNotify;
pub const GenericEvent = c.GenericEvent;

pub const XClassHint = c.XClassHint;
pub const XGetClassHint = c.XGetClassHint;
pub const XWMHints = c.XWMHints;
pub const XGetWMHints = c.XGetWMHints;
pub const XSetWMHints = c.XSetWMHints;
pub const XSizeHints = c.XSizeHints;
pub const XGetWMNormalHints = c.XGetWMNormalHints;
pub const XGetTransientForHint = c.XGetTransientForHint;
pub const XTextProperty = c.XTextProperty;
pub const XGetTextProperty = c.XGetTextProperty;
pub const XmbTextPropertyToTextList = c.XmbTextPropertyToTextList;
pub const XFreeStringList = c.XFreeStringList;
pub const Success = c.Success;
pub const XGetWMProtocols = c.XGetWMProtocols;
pub const XAllocSizeHints = c.XAllocSizeHints;

pub const XUrgencyHint = c.XUrgencyHint;
pub const InputHint = c.InputHint;
pub const PBaseSize = c.PBaseSize;
pub const PMinSize = c.PMinSize;
pub const PMaxSize = c.PMaxSize;
pub const PResizeInc = c.PResizeInc;
pub const PAspect = c.PAspect;
pub const PSize = c.PSize;

pub const XA_WM_NAME = c.XA_WM_NAME;
pub const XA_WINDOW = c.XA_WINDOW;
pub const XA_STRING = c.XA_STRING;
pub const PropModeAppend = c.PropModeAppend;
pub const NoEventMask = c.NoEventMask;

pub const XPropertyEvent = c.XPropertyEvent;
pub const PropertyDelete = c.PropertyDelete;
pub const XA_WM_TRANSIENT_FOR = c.XA_WM_TRANSIENT_FOR;
pub const XA_WM_NORMAL_HINTS = c.XA_WM_NORMAL_HINTS;
pub const XA_WM_HINTS = c.XA_WM_HINTS;

pub const XDeleteProperty = c.XDeleteProperty;
pub const XCreateSimpleWindow = c.XCreateSimpleWindow;
pub const XDestroyWindow = c.XDestroyWindow;
pub const XGrabServer = c.XGrabServer;
pub const XUngrabServer = c.XUngrabServer;
pub const XUngrabButton = c.XUngrabButton;
pub const XUngrabKey = c.XUngrabKey;
pub const XGrabKeyboard = c.XGrabKeyboard;
pub const XUngrabKeyboard = c.XUngrabKeyboard;
pub const AnyKey = c.AnyKey;
pub const AnyModifier = c.AnyModifier;

pub const Cursor = c.Cursor;
pub const XCreateFontCursor = c.XCreateFontCursor;
pub const XFreeCursor = c.XFreeCursor;
pub const XDefineCursor = c.XDefineCursor;
pub const XC_left_ptr = c.XC_left_ptr;
pub const XC_sizing = c.XC_sizing;
pub const XC_fleur = c.XC_fleur;

pub const XAllowEvents = c.XAllowEvents;
pub const ReplayPointer = c.ReplayPointer;
pub const AnyButton = c.AnyButton;

pub const XMappingEvent = c.XMappingEvent;
pub const XRefreshKeyboardMapping = c.XRefreshKeyboardMapping;
pub const MappingKeyboard = c.MappingKeyboard;
pub const MappingModifier = c.MappingModifier;
