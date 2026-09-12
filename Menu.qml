import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import qs.services as OmarchyServices
import "MenuModel.js" as MenuModel

Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // Plugin lifecycle hooks. The host calls open(payloadJson) after
  // `omarchy-shell shell summon omarchy.menu ...` and close() when hidden.
  property string pendingInitialMenu: "root"

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    if (payload.mode === "select" || payload.mode === "input") {
      root.openDmenu(payload)
    } else {
      root.openRoute(payload.initialMenu || payload.menu || "root")
    }
  }

  function close() {
    root.cancel()
  }

  function refresh() {
    root.readDefaultMenu()
    root.readUserMenu()
    return "ok"
  }

  function ping() { return "ok" }

  property string fontFamily: Style.font.menuFamily

  // ------------------------------------------------------------------ look
  // This fork adds a live "Menu Look" editor (a row under Style). The knobs
  // live in one small JSON file only this menu reads. By default they are a
  // single shared look that survives every theme switch; a theme can opt out
  // and keep its own override, stored under its slug in the same file. Every
  // knob has an inherit sentinel, so with nothing saved at either level the
  // menu renders exactly like the stock one.
  readonly property string lookConfigChain: ".local/state/omarchy/io.github.omamenu"
  readonly property string lookConfigLeaf: "style.json"
  readonly property string lookConfigDir: Quickshell.env("HOME") + "/" + lookConfigChain
  readonly property string lookConfigPath: lookConfigDir + "/" + lookConfigLeaf
  // Same file OmaShuffle reads to know the active theme.
  readonly property string currentThemeNamePath: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme.name"

  property string currentThemeSlug: "default"
  property var lookProfiles: ({})    // theme slug -> {scale, cornerRadius, borderWidth, transparency}

  // Key the shared look is stored under, alongside the per-theme overrides.
  // "*" can never collide with a theme slug - those are validated against
  // /^[a-z0-9][a-z0-9._-]*$/ before being used as a key - so the two kinds
  // of entry share one flat map without a nesting change to the file.
  readonly property string globalLookKey: "*"
  // Which entry the editor writes to. True (the default) is the shared look;
  // it only flips while the current theme carries an override of its own.
  property bool lookScopeGlobal: true

  property real cfgScale: 1.0        // card render scale
  property int cfgCornerRadius: -1   // -1 -> Style.cornerRadius
  property int cfgBorderWidth: -1    // -1 -> Math.max(1, Style.space(2))
  property int cfgTransparency: 0    // 0..90, percent off the card background

  readonly property int effCornerRadius: cfgCornerRadius >= 0 ? cfgCornerRadius : Style.cornerRadius
  readonly property int effBorderWidth: cfgBorderWidth >= 0 ? cfgBorderWidth : Math.max(1, Style.space(2))

  function clampProfile(raw) {
    var p = raw || {}
    var s = Number(p.scale)
    var cr = Number(p.cornerRadius)
    var bw = Number(p.borderWidth)
    var t = Number(p.transparency)
    return {
      scale: (isFinite(s) && s > 0) ? Math.max(0.8, Math.min(1.5, s)) : 1.0,
      cornerRadius: (isFinite(cr) && cr >= 0) ? Math.min(24, Math.round(cr)) : -1,
      borderWidth: (isFinite(bw) && bw >= 0) ? Math.min(6, Math.round(bw)) : -1,
      transparency: (isFinite(t) && t > 0) ? Math.max(0, Math.min(90, Math.round(t))) : 0
    }
  }

  // Loads/replaces the whole per-theme map (startup, or an external edit to
  // the file) and re-applies whichever theme is current.
  function applyLookConfig(raw) {
    var parsed = {}
    try { parsed = JSON.parse(raw || "{}") || {} } catch (e) { parsed = {} }
    if (Array.isArray(parsed) || typeof parsed !== "object") parsed = {}
    root.lookProfiles = parsed
    root.applyProfileForCurrentTheme()
  }

  // One stored entry, or null when there is none - or when the file holds
  // something that isn't an object under that key.
  function lookEntry(key) {
    var p = root.lookProfiles ? root.lookProfiles[key] : null
    return (p && typeof p === "object" && !Array.isArray(p)) ? p : null
  }

  // Pulls the knobs that apply right now into the live cfg* properties:
  // this theme's override if it has one, otherwise the shared look,
  // otherwise the inherit defaults. Also re-points the editor's scope at
  // whichever of the two the current theme is actually using. Called on
  // load and whenever the active theme changes.
  function applyProfileForCurrentTheme() {
    var own = root.lookEntry(root.currentThemeSlug)
    var p = root.clampProfile(own || root.lookEntry(root.globalLookKey))
    root.lookScopeGlobal = !own
    root.cfgScale = p.scale
    root.cfgCornerRadius = p.cornerRadius
    root.cfgBorderWidth = p.borderWidth
    root.cfgTransparency = p.transparency
  }

  // Writes the live knobs into whichever entry the scope points at. Saving
  // the shared look also drops this theme's override: leaving it in place
  // would shadow what was just written, so the edit would appear to vanish
  // on the next load.
  function saveLookConfig() {
    var next = {}
    for (var k in root.lookProfiles) next[k] = root.lookProfiles[k]
    var entry = {
      scale: Number(root.cfgScale.toFixed(2)),
      cornerRadius: root.cfgCornerRadius,
      borderWidth: root.cfgBorderWidth,
      transparency: root.cfgTransparency
    }
    if (root.lookScopeGlobal) {
      next[root.globalLookKey] = entry
      delete next[root.currentThemeSlug]
    } else {
      next[root.currentThemeSlug] = entry
    }
    root.lookProfiles = next
    root.writeLookConfig(JSON.stringify(next, null, 2) + "\n")
  }

  // Editor scope switch. The live knobs never move - only where they land.
  function setLookScopeGlobal(g) {
    if (root.lookScopeGlobal === g) return
    root.lookScopeGlobal = g
    root.saveLookConfig()
  }

  // Drops the entry the scope points at entirely rather than writing back
  // today's theme-derived numbers, so whatever is left keeps tracking the
  // theme (not just today's instance of it) after a reset. Clearing an
  // override rejoins the shared look; clearing the shared look falls back to
  // the stock defaults. applyProfileForCurrentTheme() then re-points the
  // scope at whichever entry survived.
  function resetLookConfig() {
    var drop = root.lookScopeGlobal ? root.globalLookKey : root.currentThemeSlug
    var next = {}
    for (var k in root.lookProfiles) if (k !== drop) next[k] = root.lookProfiles[k]
    root.lookProfiles = next
    root.applyProfileForCurrentTheme()
    root.writeLookConfig(JSON.stringify(next, null, 2) + "\n")
  }

  // style.json and current/theme.name both live under ~/.local/state, where
  // another local process could plant a symlink, a FIFO, or an oversized
  // file at the path before this plugin touches it. Every read here goes
  // through a descriptor-pinned, byte-capped, deadlined helper rather than a
  // FileView: `timeout` bounds wall time, `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`
  // refuses a symlink and never blocks on a FIFO, an `fstat` on that same
  // descriptor requires a regular file, and reads stop at limit+1 bytes.
  readonly property int maxLookConfigBytes: 65536
  readonly property int readDeadlineSecs: 5

  // Fork-wide producer/consumer bounds and deadlines. The built-in menu runs
  // a handful of `bash -lc` helpers (providers, `when:`/`checked:` guards)
  // and reads two JSONC files; upstream leaves their output and wall time
  // unbounded. This clone caps every subprocess to `procDeadlineSecs` and
  // `maxProcOutputBytes`, every menu file to `maxMenuFileBytes`, and the
  // IPC-supplied dmenu payload to `maxDmenuOptions` * `maxDmenuStringLen`.
  readonly property int procDeadlineSecs: 8
  readonly property int maxProcOutputBytes: 262144
  readonly property int maxMenuFileBytes: 262144
  readonly property int maxDmenuOptions: 4000
  readonly property int maxDmenuStringLen: 8192
  // Model cardinality: a stream that stays under the byte cap can still fan
  // out into thousands of rows, so provider rows, parsed menu items and
  // guard result lines each get an explicit count cap and per-field length.
  readonly property int maxProviderRows: 2000
  readonly property int maxMenuItems: 6000
  readonly property int maxGuardLines: 8000
  readonly property int maxFieldLen: 4096
  // Aggregate bounds. The per-item and per-field caps above still permit a
  // very large *total*, and for a script handed to a child process the total
  // is the bound that matters: argv is capped by ARG_MAX long before any
  // runner deadline or output limit can apply. Both are checked before a
  // process is spawned, and both fail closed.
  readonly property int maxGuardCount: 2000
  readonly property int maxScriptBytes: 262144
  // The native apps provider snapshots DesktopEntries straight into the
  // long-lived model, so it needs the same shape of bounds the JSONC path has.
  readonly property int maxAppRows: 4000
  readonly property int maxAppAliases: 64
  readonly property int maxAppBytes: 1048576

  // Byte length of `s` once Qt encodes it as UTF-8 on the way to a child's
  // stdin. The framed protocol below sends a byte count and QML strings are
  // UTF-16, so the two have to agree exactly. A lone surrogate counts as the
  // 3-byte replacement character, which is what that conversion emits.
  function utf8ByteLen(s) {
    var n = 0
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i)
      if (c < 0x80) { n += 1; continue }
      if (c < 0x800) { n += 2; continue }
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
        var d = s.charCodeAt(i + 1)
        if (d >= 0xDC00 && d <= 0xDFFF) { n += 4; i += 1; continue }
      }
      n += 3
    }
    return n
  }

  // One framed stdin payload: a decimal UTF-8 byte count, a newline, then
  // exactly that many bytes. Framing means the reader never depends on EOF -
  // QML has no way to close a child's stdin - and never reads past its limit.
  function framedPayload(text) {
    var s = String(text || "")
    return String(root.utf8ByteLen(s)) + "\n" + s
  }

  // Refuses an oversized script before any process is spawned.
  function scriptTooBig(script) {
    return root.utf8ByteLen(String(script || "")) > root.maxScriptBytes
  }
  function deadlined(argv) {
    return ["timeout", "-k", "2", String(root.procDeadlineSecs)].concat(argv)
  }

  // Runs a `bash` helper under a hard byte ceiling and a hard deadline, and
  // returns its stdout.
  //
  // The script itself is NOT in argv. It arrives framed on this runner's
  // stdin (a decimal byte count, a newline, then exactly that many bytes) and
  // is handed to `bash -l -s` over a pipe, so it appears in no process's
  // argv: not this runner's, not the producer's. That keeps a `when:`/
  // `checked:` guard batch or a provider script - which can legitimately be
  // large, and can carry private text - out of world-readable
  // /proc/<pid>/cmdline, and off the ARG_MAX budget that would otherwise
  // reject the exec outright before any of the limits below could apply.
  //
  // exit 0 ok / 3 byte overflow or oversized frame / 4 producer failed,
  // unreaped, or a malformed frame / 5 deadline.
  //
  // The deadline is enforced here, not by the outer `timeout`: the producer
  // runs in its own session, and its stdin and stdout are driven together in
  // one non-blocking select() loop under the budget, so a producer that never
  // drains the script cannot deadlock against a producer that never speaks.
  // The finally always TERM->KILLs and reaps the whole session - on EOF,
  // overflow, the internal deadline, or a SIGTERM from QML destroying the
  // Process (a handler turns that into the same path).
  readonly property string cappedRunnerScript: [
    "import os,sys,signal,subprocess,select,time",
    "limit=int(sys.argv[1]); budget=float(sys.argv[2])",
    "def rd(fd,n):",
    "    b=bytearray()",
    "    while len(b)<n:",
    "        try: c=os.read(fd,n-len(b))",
    "        except InterruptedError: continue",
    "        except OSError: return None",
    "        if not c: return None",
    "        b+=c",
    "    return bytes(b)",
    "# framed stdin: decimal byte count, newline, exactly that many bytes",
    "hdr=bytearray()",
    "while True:",
    "    c=rd(0,1)",
    "    if c is None: sys.exit(4)",
    "    if c==b'\\n': break",
    "    hdr+=c",
    "    if len(hdr)>24: sys.exit(4)",
    "try: need=int(hdr.decode('ascii'))",
    "except Exception: sys.exit(4)",
    "if need<0 or need>limit: sys.exit(3)",
    "script=rd(0,need) if need else b''",
    "if script is None: sys.exit(4)",
    "class Stop(Exception): pass",
    "def _sig(*a): raise Stop()",
    "signal.signal(signal.SIGTERM,_sig); signal.signal(signal.SIGINT,_sig)",
    "p=subprocess.Popen(['bash','-l','-s'], stdin=subprocess.PIPE,",
    "                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,",
    "                   start_new_session=True)",
    "sin=p.stdin.fileno(); sout=p.stdout.fileno()",
    "out=bytearray(); overflow=False; expired=False",
    "mv=memoryview(script)",
    "end=time.monotonic()+budget",
    "def shut():",
    "    global mv",
    "    mv=None",
    "    try: p.stdin.close()",
    "    except Exception: pass",
    "try:",
    "    os.set_blocking(sout,False); os.set_blocking(sin,False)",
    "    if not mv: shut()",
    "    while True:",
    "        left=end-time.monotonic()",
    "        if left<=0: expired=True; break",
    "        ws=[sin] if mv is not None else []",
    "        r,w,_=select.select([sout],ws,[],min(left,0.25))",
    "        if w:",
    "            try: n=os.write(sin,mv)",
    "            except (BlockingIOError,InterruptedError): n=0",
    "            except OSError: n=-1",
    "            if n<0: shut()",
    "            else:",
    "                mv=mv[n:]",
    "                if not mv: shut()",
    "        if r:",
    "            try: chunk=os.read(sout,65536)",
    "            except (BlockingIOError,InterruptedError): chunk=None",
    "            except OSError: chunk=b''",
    "            if chunk==b'': break",
    "            if chunk:",
    "                out+=chunk",
    "                if len(out)>limit: overflow=True; break",
    "        elif not w and mv is None and p.poll() is not None: break",
    "except Stop:",
    "    expired=True",
    "finally:",
    "    shut()",
    "    for s in (signal.SIGTERM, signal.SIGKILL):",
    "        try: os.killpg(p.pid, s)",
    "        except OSError: break",
    "        try:",
    "            p.wait(timeout=1.5); break",
    "        except subprocess.TimeoutExpired:",
    "            continue",
    "    try: p.wait(timeout=0.5)",
    "    except Exception: pass",
    "rc=p.returncode",
    "if overflow: sys.exit(3)",
    "if expired: sys.exit(5)",
    "if rc!=0: sys.exit(4)",
    "sys.stdout.buffer.write(bytes(out))",
    "sys.exit(0)"
  ].join("\n")

  // argv carries only the limits; the caller sets `pendingScript` on its
  // Process and writes root.framedPayload(...) to stdin in onStarted. The
  // internal budget is the real deadline; the outer `timeout` is a last
  // resort a couple of seconds later.
  function bashCappedCommand() {
    return root.deadlined(["python3", "-c", root.cappedRunnerScript,
                           String(root.maxProcOutputBytes),
                           String(root.procDeadlineSecs - 2)])
  }

  readonly property string boundedReaderScript: [
    "import os,sys,stat",
    "path=sys.argv[1]; limit=int(sys.argv[2])",
    "try:",
    "    fd=os.open(path, os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)",
    "except OSError:",
    "    sys.exit(2)",
    "try:",
    "    if not stat.S_ISREG(os.fstat(fd).st_mode):",
    "        sys.exit(3)",
    "    chunks=[]; total=0",
    "    while total <= limit:",
    "        try:",
    "            chunk=os.read(fd, (limit + 1) - total)",
    "        except BlockingIOError:",
    "            break",
    "        if not chunk: break",
    "        chunks.append(chunk); total += len(chunk)",
    "    if total > limit:",
    "        sys.exit(4)",
    "    sys.stdout.buffer.write(b''.join(chunks))",
    "finally:",
    "    os.close(fd)"
  ].join("\n")

  // Writes: every step after the leaf directory is opened is relative to
  // that held directory fd, so the path is resolved once and never re-walked
  // (no TOCTOU between check, create and rename). The dir is opened
  // O_DIRECTORY|O_NOFOLLOW (a symlinked state dir fails the open) and
  // fstat-checked for S_ISDIR + our uid; any existing target must be a
  // regular non-symlink file; the temp is created O_CREAT|O_EXCL|O_NOFOLLOW
  // mode 0600 via openat, written in a short-write loop, fsync'd, then
  // renameat'd over the target, and the directory itself is fsync'd.
  // argv: <json bytes> <chain> <leaf name>, where <chain> is the state dir
  // split on '/' relative to $HOME. Starting from an fd on $HOME, each
  // component is mkdir'd (0700) then re-opened O_DIRECTORY|O_NOFOLLOW - so
  // no element of the chain can be a symlink an attacker planted - and the
  // held fd is advanced. The final dir fd is fstat-checked (S_ISDIR + our
  // uid); any existing leaf must be a regular non-symlink file; the temp
  // uses a random adjacent name created O_CREAT|O_EXCL|O_NOFOLLOW 0600 via
  // openat; the body is written in a short-write loop and fsync'd; then
  // renameat over the leaf and the directory fd is fsync'd. Every create,
  // stat, open and rename is relative to a held fd, never a re-walked path.
  readonly property string boundedWriterScript: [
    "import os,sys,stat",
    "data=sys.argv[1].encode(); chain=[c for c in sys.argv[2].split('/') if c]; name=sys.argv[3]",
    "if '..' in chain or '..' in (name, '.') or '/' in name:",
    "    sys.exit(5)",
    "try:",
    "    dfd=os.open(os.path.expanduser('~'), os.O_RDONLY|os.O_DIRECTORY)",
    "except OSError:",
    "    sys.exit(2)",
    "try:",
    "    for c in chain:",
    "        try:",
    "            os.mkdir(c, 0o700, dir_fd=dfd)",
    "        except FileExistsError:",
    "            pass",
    "        except OSError:",
    "            sys.exit(2)",
    "        try:",
    "            nfd=os.open(c, os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW, dir_fd=dfd)",
    "        except OSError:",
    "            sys.exit(3)",
    "        os.close(dfd); dfd=nfd",
    "        cst=os.fstat(dfd)",
    "        # every component must be ours and not group/other writable",
    "        if cst.st_uid != os.getuid() or (cst.st_mode & 0o022):",
    "            sys.exit(3)",
    "    st=os.fstat(dfd)",
    "    if not stat.S_ISDIR(st.st_mode):",
    "        sys.exit(3)",
    "    try:",
    "        ex=os.stat(name, dir_fd=dfd, follow_symlinks=False)",
    "        # an existing leaf must be a private regular file we own",
    "        if not stat.S_ISREG(ex.st_mode) or ex.st_uid != os.getuid() or (ex.st_mode & 0o077):",
    "            sys.exit(4)",
    "    except FileNotFoundError:",
    "        pass",
    "    except OSError:",
    "        sys.exit(4)",
    "    tmp='.'+name+'.'+os.urandom(8).hex()",
    "    fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600, dir_fd=dfd)",
    "    try:",
    "        mv=memoryview(data)",
    "        while mv:",
    "            mv=mv[os.write(fd, mv):]",
    "        os.fsync(fd)",
    "    finally:",
    "        os.close(fd)",
    "    try:",
    "        os.rename(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)",
    "    except OSError:",
    "        try: os.unlink(tmp, dir_fd=dfd)",
    "        except OSError: pass",
    "        raise",
    "    os.fsync(dfd)",
    "finally:",
    "    os.close(dfd)"
  ].join("\n")

  function readBounded(proc, path, limit) {
    proc.command = ["timeout", "-k", "2", String(root.readDeadlineSecs),
                    "python3", "-c", root.boundedReaderScript, path, String(limit)]
    proc.running = true
  }

  function readLookConfig() { root.readBounded(lookConfigReadProc, root.lookConfigPath, root.maxLookConfigBytes) }
  function readThemeName() { root.readBounded(themeNameReadProc, root.currentThemeNamePath, 256) }

  function writeLookConfig(text) {
    lookConfigWriteProc.command = ["timeout", "-k", "2", String(root.readDeadlineSecs),
                                   "python3", "-c", root.boundedWriterScript,
                                   String(text), root.lookConfigChain, root.lookConfigLeaf]
    lookConfigWriteProc.running = true
  }

  Process {
    id: lookConfigReadProc
    stdout: StdioCollector { id: lookConfigReadOut; waitForEnd: true }
    onExited: function (code) {
      if (code === 3) console.warn("Menu Look: style.json is not a regular file - ignoring it")
      if (code === 4) console.warn("Menu Look: style.json exceeds " + root.maxLookConfigBytes + " bytes - ignoring it")
      root.applyLookConfig(code === 0 ? lookConfigReadOut.text : "")
    }
  }

  Process {
    id: lookConfigWriteProc
    onExited: function (code) {
      if (code !== 0) console.warn("Menu Look: could not write style.json (exit " + code + ")")
    }
  }

  Process {
    id: themeNameReadProc
    stdout: StdioCollector { id: themeNameReadOut; waitForEnd: true }
    onExited: function (code) {
      // Same slug shape OmaShuffle validates theme names against before
      // trusting one - this value becomes a JSON object key and is written
      // back into our own state file.
      var slug = (code === 0 ? String(themeNameReadOut.text || "") : "").trim().slice(0, 128)
      root.currentThemeSlug = /^[a-z0-9][a-z0-9._-]*$/.test(slug) ? slug : "default"
    }
  }

  Component.onCompleted: {
    root.readLookConfig()
    root.readThemeName()
    root.readDefaultMenu()
    root.readUserMenu()
  }

  // A FileView used only as a change notifier (no read through it) so
  // switching themes - this plugin's picker, `omarchy theme set`, a rotator
  // like OmaShuffle - re-resolves Menu Look live, which changes anything only
  // when a theme on either side of the switch carries its own override. The
  // content is pulled by the bounded reader above.
  FileView {
    id: themeNameWatcher
    path: root.currentThemeNamePath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readThemeName()
  }
  onCurrentThemeSlugChanged: root.applyProfileForCurrentTheme()

  // JSONC menu definitions. The shell parses both at startup and merges
  // the user file on top of the defaults, so the keybind → IPC → visible
  // path doesn't have to shell out to bash + jq on every open.
  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property bool opened: false
  property string mode: "menu"
  readonly property bool dmenuActive: mode === "select" || mode === "input"
  property string dmenuPrompt: ""
  property var dmenuOptions: []
  property string selectionFile: ""
  property string doneFile: ""
  property int dmenuWidth: 300
  property int dmenuMaxHeight: 0
  property bool requestActive: false
  property bool rowsLoaded: false
  property string activeMenu: "root"
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property int requestSerial: 0
  property int applySerial: 0
  property var items: ({})
  property var itemOrder: []
  property var navStack: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0

  // Shared application engine (entries, hidden filters, icons, launch,
  // removal), owned by the shell and also used by the standalone launcher.
  // Omarchy 4.0.3 builds a panel-hosted menu's API from the Instantiator's
  // modelData manifest, where `kinds` is a V4Sequence that Array.isArray()
  // rejects - so manifestHasKind(..., "menu") fails and appLibrary arrives
  // null. The next plugin rescan then revokes that API over the profile
  // mismatch, leaving root.shell itself null. Until that is fixed upstream,
  // run a private AppLibrary whenever the shell's isn't reachable.
  readonly property var appLibrary: (root.shell && root.shell.appLibrary)
    ? root.shell.appLibrary : fallbackAppLibrary.item
  Loader {
    id: fallbackAppLibrary
    active: !(root.shell && root.shell.appLibrary)
    sourceComponent: OmarchyServices.AppLibrary { }
  }
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  onOpenedChanged: if (!opened) { deleteConfirmOpen = false; deleteTarget = null }
  // Bound to the central [menu] section in shell.toml via Color.qml.
  // Each color already includes its alpha companion (composed in the
  // singleton), so consumers can drop them straight into a Rectangle.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, root.effBorderWidth)
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property real rowReservedBorderLeft: Border.left(selectedBorderSpec)
  readonly property real rowReservedBorderRight: Border.right(selectedBorderSpec)
  readonly property int cornerRadius: root.effCornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int baseRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  property int detailRowHeight: Math.max(Style.space(58), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  // How much of the first hidden row stays visible at the fold — enough to
  // read as a cut-off row rather than a bottom border.
  property int rowPeek: Math.round(baseRowHeight * 0.55)
  property int rowSpacing: Style.spacing.xs
  property int dividerHeight: Style.space(17)
  property bool searchDivider: false
  property int layoutSerial: 0
  property int cardWidth: Math.min(root.dmenuActive ? Style.space(root.dmenuWidth) : ((root.activeMenu === "trigger.capture.screenrecord" || root.activeMenu === "style.font" || root.activeMenu === "style.menu-look") ? Style.space(520) : Style.space(300)), panel.width - Style.gapsOut * 2)
  property int visibleRowsHeight: root.dmenuActive ? dmenuRowListHeight(layoutSerial, displayModel.count, filterText) : rowListHeight(layoutSerial, displayModel.count, filterText, searchDivider)
  property int cardHeight: root.dmenuActive
    ? Math.min(contentMargin * 2 + headerHeight + (mode === "input" ? 0 : contentSpacing + visibleRowsHeight), panel.height - Style.gapsOut * 2)
    : root.activeMenu === "style.menu-look"
      ? Math.min(contentMargin * 2 + Math.max(Style.space(220), lookEditor.implicitHeight), panel.height - Style.gapsOut * 2)
      : Math.min(contentMargin * 2 + headerHeight + contentSpacing + visibleRowsHeight, panel.height - Style.gapsOut * 2)

  // select/input mode result files. Both paths come from the IPC payload
  // (the caller-side `omarchy-menu-select` / `-input` helpers mktemp them),
  // so upstream's `bash -c "printf … > $path"` is replaced with a helper
  // that: rejects a non-absolute path or one with a `..` segment, opens each
  // with O_WRONLY|O_NOFOLLOW (a planted symlink at the path fails), caps the
  // selection payload, fsyncs, and always touches doneFile last so a waiting
  // caller is released. argv carries only selectionFile, doneFile and
  // hasSelection; the value itself arrives framed on stdin.
  readonly property int maxSelectionBytes: 65536
  // select/input result-file writer. The two paths come from the IPC payload;
  // the stock `omarchy-menu-select` / `-input` callers mktemp them under
  // $TMPDIR, so a result slot must resolve into $XDG_RUNTIME_DIR / $TMPDIR /
  // /tmp / /var/tmp (blocks e.g. ~/.bashrc), and any pre-existing slot must
  // be a private (0600) regular file we own - which is exactly what mktemp
  // leaves and not an arbitrary user file. The write itself is an O_EXCL
  // adjacent temp + renameat, all relative to the held parent fd; doneFile is
  // only ever created/left as an empty 0600 file so a waiting caller is
  // released.
  //
  // Two different directory rules, because "sticky and world-writable" is a
  // property of a temp root and of nothing below it. The matched root may be
  // the /tmp shape (sticky + world-writable) or ours-and-private; every
  // component walked *below* it must be ours with no group/other write bit,
  // so a user-owned but group-writable subdirectory can no longer let another
  // local user swap request slots mid-protocol. The selected value never
  // touches argv: it is framed on stdin exactly like the capped runner's
  // script, so private dmenu input stays out of /proc/<pid>/cmdline.
  readonly property string resultWriterScript: [
    "import os,sys,stat",
    "sel,done,has=sys.argv[1],sys.argv[2],sys.argv[3]=='1'",
    "LIMIT=65536",
    "def rd(fd,n):",
    "    b=bytearray()",
    "    while len(b)<n:",
    "        try: c=os.read(fd,n-len(b))",
    "        except InterruptedError: continue",
    "        except OSError: return None",
    "        if not c: return None",
    "        b+=c",
    "    return bytes(b)",
    "val=b''",
    "def read_value():",
    "    # framed stdin: decimal byte count, newline, exactly that many bytes.",
    "    # Returns None if the frame is malformed or over LIMIT; the caller then",
    "    # degrades to 'no selection' rather than exiting, because an exit here",
    "    # would skip the doneFile write below and hang the waiting helper.",
    "    hdr=bytearray()",
    "    while True:",
    "        c=rd(0,1)",
    "        if c is None: return None",
    "        if c==b'\\n': break",
    "        hdr+=c",
    "        if len(hdr)>24: return None",
    "    try: need=int(hdr.decode('ascii'))",
    "    except Exception: return None",
    "    if need<0 or need>LIMIT: return None",
    "    return (rd(0,need) if need else b'')",
    "if has:",
    "    val=read_value()",
    "    if val is None: has=False",
    "uid=os.getuid()",
    "roots=[os.path.realpath(r) for r in (os.environ.get('XDG_RUNTIME_DIR'),os.environ.get('TMPDIR'),'/tmp','/var/tmp') if r]",
    "def priv_ok(st):",
    "    # ours, and not writable by group or other",
    "    return stat.S_ISDIR(st.st_mode) and st.st_uid==uid and not (st.st_mode & 0o022)",
    "def root_ok(st):",
    "    # a temp ROOT may also be the sticky world-writable /tmp shape; that",
    "    # rule is deliberately confined to the root and never inherited",
    "    return priv_ok(st) or (stat.S_ISDIR(st.st_mode) and (st.st_mode & stat.S_ISVTX) and (st.st_mode & 0o002))",
    "def open_parent(d):",
    "    # d must start at one of the temp roots; walk the remainder",
    "    # component-by-component with held FDs, O_NOFOLLOW past the root.",
    "    comps=[c for c in d.split('/') if c]",
    "    root=None; ri=0",
    "    for r in roots:",
    "        rc=[c for c in r.split('/') if c]",
    "        if comps[:len(rc)]==rc: root=r; ri=len(rc); break",
    "    if root is None: return None",
    "    try: fd=os.open(root, os.O_RDONLY|os.O_DIRECTORY)",
    "    except OSError: return None",
    "    if not root_ok(os.fstat(fd)): os.close(fd); return None",
    "    for c in comps[ri:]:",
    "        try: nfd=os.open(c, os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW, dir_fd=fd)",
    "        except OSError: os.close(fd); return None",
    "        os.close(fd); fd=nfd",
    "        if not priv_ok(os.fstat(fd)): os.close(fd); return None",
    "    return fd",
    "def slot(p, data):",
    "    if not (p.startswith('/') and '..' not in p.split('/') and '\\0' not in p): return",
    "    d,name=os.path.dirname(p),os.path.basename(p)",
    "    if not name or '/' in name: return",
    "    dfd=open_parent(d)",
    "    if dfd is None: return",
    "    try:",
    "        # no re-check here: open_parent validated this exact fd and the",
    "        # path is never re-walked, so there is no window to re-validate",
    "        try:",
    "            ex=os.stat(name, dir_fd=dfd, follow_symlinks=False)",
    "            if not stat.S_ISREG(ex.st_mode) or ex.st_uid!=uid or (ex.st_mode & 0o077): return",
    "        except FileNotFoundError:",
    "            pass",
    "        except OSError:",
    "            return",
    "        if data is None:",
    "            try: os.close(os.open(name, os.O_WRONLY|os.O_CREAT|os.O_NOFOLLOW, 0o600, dir_fd=dfd))",
    "            except OSError: pass",
    "            return",
    "        tmp='.'+name+'.'+os.urandom(8).hex()",
    "        fd=os.open(tmp, os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW, 0o600, dir_fd=dfd)",
    "        try:",
    "            mv=memoryview(data[:65536])",
    "            while mv: mv=mv[os.write(fd, mv):]",
    "            os.fsync(fd)",
    "        finally:",
    "            os.close(fd)",
    "        try:",
    "            os.rename(tmp, name, src_dir_fd=dfd, dst_dir_fd=dfd)",
    "        except OSError:",
    "            try: os.unlink(tmp, dir_fd=dfd)",
    "            except OSError: pass",
    "    finally:",
    "        os.close(dfd)",
    "if has: slot(sel, val + b'\\n')",
    "slot(done, None)"
  ].join("\n")

  function finishRequest(selection) {
    if (!root.requestActive || !root.doneFile) {
      root.opened = false
      return
    }

    var activeSelectionFile = root.selectionFile
    var activeDoneFile = root.doneFile
    var hasSelection = !(selection === null || selection === undefined)
    root.requestActive = false
    root.selectionFile = ""
    root.doneFile = ""

    resultProc.pendingValue = hasSelection
      ? String(selection).slice(0, root.maxSelectionBytes)
      : ""
    resultProc.hasSelection = hasSelection
    resultProc.command = root.deadlined(["python3", "-c", root.resultWriterScript,
      activeSelectionFile, activeDoneFile,
      hasSelection ? "1" : "0"])
    resultProc.running = true
  }

  function runAction(action) {
    var command = String(action || "")
    if (!command) return

    Util.execDetached(command)
  }

  // Menu rows only surface their detail while a search is narrowing them;
  // dmenu rows carry caller-supplied subtext that must always be visible.
  function rowHeightForDetail(detail) {
    return (root.filterText || root.dmenuActive) && detail ? root.detailRowHeight : root.baseRowHeight
  }

  // Height the card can devote to rows before running off the screen — or
  // past the frozen top edge once a search has pinned the card in place.
  // Uses panel.cardTop rather than effectiveCardTop: the centered top is
  // derived from the card height, which this value feeds.
  function availableRowsHeight() {
    var top = panel.cardTop >= 0 ? panel.cardTop : Style.gapsOut
    var available = panel.height - top - Style.gapsOut - root.contentMargin * 2 - root.headerHeight - root.contentSpacing
    // The starting menu sets the ceiling along with the offset: drilling into
    // a longer submenu scrolls behind the fold instead of growing the card.
    if (panel.maxRowsHeight >= 0) available = Math.min(available, panel.maxRowsHeight)
    // A card that swallows the whole screen reads as a page, not a menu.
    return Math.min(available, Math.round(panel.height * 0.7))
  }

  // When every row fits, the list gets its full height. When they don't,
  // the card must end mid-row: a clipped row is what tells the eye there is
  // more below the fold, so never come out even on a row boundary.
  function foldedListHeight(totals, available) {
    var count = totals.length
    if (count === 0) return root.baseRowHeight
    if (totals[count - 1] <= available) return totals[count - 1]

    var peek = root.rowPeek
    var full = 0
    while (full < count && totals[full] <= available) full++
    while (full > 1 && totals[full - 1] + root.rowSpacing + peek > available) full--
    if (full < 1) return Math.max(available, root.baseRowHeight)

    return totals[full - 1] + root.rowSpacing + peek
  }

  function rowListHeight(_serial, _count, _filter, _divider) {
    if (displayModel.count === 0) return root.baseRowHeight

    var totals = []
    var total = 0
    var previousSection = ""

    for (var i = 0; i < displayModel.count; i++) {
      var row = displayModel.get(i)
      if (i > 0) total += root.rowSpacing
      if (row.section === "drilldown" && previousSection !== "drilldown") total += root.dividerHeight
      total += root.rowHeightForDetail(row.detail)
      previousSection = row.section
      totals.push(total)
    }

    return foldedListHeight(totals, availableRowsHeight())
  }

  function dmenuRowListHeight(_serial, _count, _filter) {
    if (root.mode === "input") return 0
    if (displayModel.count === 0) return root.baseRowHeight

    var available = availableRowsHeight()
    if (root.dmenuMaxHeight > 0) available = Math.min(available, Style.space(root.dmenuMaxHeight))

    var totals = []
    var total = 0
    for (var i = 0; i < displayModel.count; i++) {
      if (i > 0) total += root.rowSpacing
      total += root.rowHeightForDetail(displayModel.get(i).detail)
      totals.push(total)
    }

    return foldedListHeight(totals, available)
  }

  function item(id) {
    return root.items[id] || null
  }

  // ------------------------------------------------------------------
  // JSONC → normalized item array. Mirrors the bash bin's jq pipeline so
  // the on-disk authoring format stays untouched.
  // ------------------------------------------------------------------

  function stripJsonc(raw) {
    return MenuModel.stripJsonc(raw)
  }

  function normalizeAliases(value) {
    return MenuModel.normalizeAliases(value)
  }

  function normalizeItem(id, raw) {
    return MenuModel.normalizeItem(id, raw)
  }

  function parseMenuJsonc(raw) {
    var items = MenuModel.parseMenuJsonc(raw)
    if (!Array.isArray(items)) return []
    // Fail closed on an oversized menu file: an unfamiliar/huge one is
    // dropped rather than fanned out into the model.
    if (items.length > root.maxMenuItems) return []
    // Clamp the free-text fields that reach QML text/actions.
    var keys = ["id", "parent", "label", "title", "target", "description",
                "action", "provider", "icon", "iconFont", "when", "checked"]
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      for (var k = 0; k < keys.length; k++) {
        if (typeof it[keys[k]] === "string") it[keys[k]] = it[keys[k]].slice(0, root.maxFieldLen)
      }
      if (Array.isArray(it.aliases))
        it.aliases = it.aliases.slice(0, 64).map(function(a) { return String(a).slice(0, root.maxFieldLen) })
    }
    return items
  }

  // Merge defaults + user extension. Later entries override earlier ones
  // on a per-key basis (so the user can tweak label/icon/action without
  // re-declaring the whole row).
  function rebuildItemsFromSources() {
    var mergedMenu = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    // This fork injects its own "Menu Look" row under Style. Kind "action"
    // with an empty action keeps it always-visible (isVisible() would hide a
    // childless submenu); activateIndex() intercepts it and opens the editor.
    mergedMenu.items["style.menu-look"] = {
      id: "style.menu-look", parent: "style", kind: "action",
      icon: "󰐱", iconFont: "", label: "Menu Look", title: "Menu Look",
      target: "", description: "This menu's size, corners, border and transparency",
      action: "", provider: "",
      aliases: ["menu look", "menu style", "menu appearance", "menu size"],
      when: "", checked: ""
    }
    if (mergedMenu.itemOrder.indexOf("style.menu-look") < 0)
      mergedMenu.itemOrder.push("style.menu-look")
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = mergedMenu.items
    root.itemOrder = mergedMenu.itemOrder
    root.rowsLoaded = true
    root.evaluateGuards()
    if (root.opened) {
      root.rebuildDisplay()
      if (!root.dmenuActive) {
        if (root.filterText.trim()) root.loadProvidersForSearch()
        else root.loadProviderForMenu(root.activeMenu)
      }
    }
  }

  // Each known provider is a tiny bash one-liner that enumerates a list and
  // emits one tab-delimited row per item: `label\tvalue\tcurrent`. The shell
  // turns those into menu items children of `menuId`. A `volatile` provider
  // re-runs every time its submenu is entered, so a font installed since the
  // shell started shows up without restarting it.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "\udb81\udc0b",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function slugify(value) {
    return MenuModel.slugify(value)
  }

  // The apps provider is QML-native: rows come from the shared AppLibrary
  // (DesktopEntries) instead of a bash enumeration, so they carry image
  // icons, launch feedback, and uninstall support like the launcher.
  //
  // Being native does not make it unbounded. Entries are parsed from .desktop
  // files anywhere on XDG_DATA_DIRS and land in a model that outlives the
  // menu, so this path gets the same explicit entry / field / alias-count /
  // alias-length / aggregate limits the JSONC and provider paths have - and
  // fails closed on any of them, discarding the whole snapshot rather than
  // merging a prefix and presenting it as the complete app list.
  function mergeAppRows() {
    if (!root.appLibrary) return

    var rows = root.appLibrary.sortedEntries("")
    if (rows.length > root.maxAppRows) return

    var appRows = []
    var totalBytes = 0
    for (var j = 0; j < rows.length; j++) {
      var entry = rows[j].entry
      var appId = String(entry.id || "")
      if (!appId) continue
      if (appId.length > root.maxFieldLen) return

      var subtext = String(root.appLibrary.entrySubtext(entry) || "")
      var appIcon = String(entry.icon || "")
      var label = String(root.appLibrary.entryName(entry) || "")
      if (subtext.length > root.maxFieldLen) return
      if (appIcon.length > root.maxFieldLen) return
      if (label.length > root.maxFieldLen) return

      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      if (aliases.length > root.maxAppAliases) return

      totalBytes += appId.length + subtext.length + appIcon.length + label.length
      for (var a = 0; a < aliases.length; a++) {
        aliases[a] = String(aliases[a] || "")
        if (aliases[a].length > root.maxFieldLen) return
        totalBytes += aliases[a].length
      }
      if (totalBytes > root.maxAppBytes) return

      appRows.push({
        id: "apps." + appId,
        parent: "apps",
        kind: "app",
        icon: "",
        appIcon: appIcon,
        appId: appId,
        label: label,
        title: "",
        target: "",
        description: subtext,
        action: "",
        provider: "",
        aliases: aliases,
        when: "",
        checked: "",
        order: 0
      })
    }

    var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  // Returns true only when providerProc was actually started, so the queue
  // in startNextProvider() moves on instead of stalling behind a provider
  // that ran natively or was refused.
  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return false
    if (entry.provider === "apps") {
      root.providersLoaded[id] = true
      root.mergeAppRows()
      return false
    }
    var spec = root.providers[entry.provider]
    if (!spec) return false

    root.providersLoaded[id] = true
    if (root.scriptTooBig(spec.script)) return false
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.pendingScript = spec.script
    providerProc.command = root.bashCappedCommand()
    providerProc.running = true
    return true
  }

  function mergeProviderRows(rows, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(rows || "").split("\n")
    // Fail closed on cardinality overflow, same as a byte/deadline overflow:
    // a provider decision set that would exceed the row cap is discarded, not
    // silently truncated to its prefix.
    var nonEmpty = 0
    for (var n = 0; n < lines.length; n++) if (lines[n].trim()) nonEmpty++
    if (nonEmpty > root.maxProviderRows) return
    var providerRows = []
    var takenIds = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = String(parts[0] || "").slice(0, root.maxFieldLen)
      var value = String(parts[1] || parts[0] || "").slice(0, root.maxFieldLen)
      var current = String(parts[2] || "").slice(0, root.maxFieldLen)
      if (!label) continue
      // Distinct values can slugify alike — Fira Code and Fira-Code both give
      // fira-code — and a repeated id is dropped, which would silently lose a
      // row from the list. Nudge it until it is the row's own.
      var rowId = menuId + "." + root.slugify(value)
      while (takenIds[rowId]) rowId += "-"
      takenIds[rowId] = true

      providerRows.push({
        id: rowId,
        parent: menuId,
        kind: "action",
        icon: (value === current) ? "✓" : (spec.icon || ""),
        label: label,
        title: "",
        target: "",
        description: "",
        action: spec.actionFor(value),
        provider: "",
        aliases: [],
        when: "",
        checked: "",
        order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function startNextProvider() {
    if (providerProc.running) return

    while (root.providerQueue.length > 0) {
      var id = root.providerQueue.shift()
      var entry = root.item(id)
      if (!entry || !entry.provider || root.providersLoaded[id]) continue

      if (root.startProviderForMenu(id)) return
    }
  }

  // Entering a submenu is the one moment a volatile list is worth paying for
  // again: it may have been reshaped by the last pick from it. Search doesn't
  // invalidate, or every keystroke would restart the same enumeration.
  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return

    // Native providers don't touch providerProc, so they never need to queue.
    if (entry.provider === "apps") {
      root.startProviderForMenu(id)
      return
    }

    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }

    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    var active = root.item(root.activeMenu) ? root.activeMenu : "root"

    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (!entry || !entry.provider || root.providersLoaded[entry.id]) continue
      if (active !== "root" && entry.id !== active && !root.isDescendantOf(entry.id, active)) continue

      root.loadProviderForMenu(entry.id)
    }
  }

  function depthFor(id) {
    return MenuModel.depthFor(root.items, id)
  }

  function pathFor(id) {
    return MenuModel.pathFor(root.items, id)
  }

  function parentPathFor(id) {
    return MenuModel.parentPathFor(root.items, id)
  }

  function isDescendantOf(id, ancestorId) {
    return MenuModel.isDescendantOf(root.items, id, ancestorId)
  }

  function childCount(id) {
    return MenuModel.childCount(root.items, root.itemOrder, id)
  }

  // Guarded items are hidden when their `when:` evaluates false. Static
  // submenus are also hidden when none of their descendants are visible;
  // provider-backed menus stay visible because their rows load on demand.
  function isVisible(entry) {
    return MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry)
  }

  // Label with the ✓ marker baked in when `checked:` evaluated truthy.
  function labelFor(entry) {
    return MenuModel.labelFor(entry, root.checkedResults)
  }

  function searchableToken(value) {
    return MenuModel.searchableToken(value)
  }

  function leafIdFor(id) {
    return MenuModel.leafIdFor(id)
  }

  function nameSearchText(entry) {
    return MenuModel.nameSearchText(entry)
  }

  function termInSearchWords(term, text) {
    return MenuModel.termInSearchWords(term, text)
  }

  function descriptionTextMatches(query, text) {
    return MenuModel.descriptionTextMatches(query, text)
  }

  function matchesQuery(entry, query) {
    return MenuModel.matchesQuery(entry, query, root.isVisible(entry))
  }

  function searchScore(entry, query) {
    return MenuModel.searchScore(root.items, entry, query)
  }

  function displayRow(entry, detail, score, section) {
    return MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, detail, score, section)
  }

  function rebuildDmenuDisplay() {
    displayModel.clear()
    root.searchDivider = false

    if (root.mode === "input") {
      layoutSerial += 1
      return
    }

    var query = root.filterText.trim().toLowerCase()
    for (var i = 0; i < root.dmenuOptions.length; i++) {
      // An option is "<label>", "<glyph>\t<label>", or
      // "<glyph>\t<label>\t<subtext>". The glyph never comes back with the
      // selection; the subtext renders under the label, filters alongside it,
      // and returns with the selection as a stable key for same-named rows.
      var parts = String(root.dmenuOptions[i] || "").split("\t")
      var icon = parts.length > 1 ? parts.shift() : ""
      var label = parts.shift() || ""
      var detail = parts.join("\t")
      if (query && label.toLowerCase().indexOf(query) < 0
          && detail.toLowerCase().indexOf(query) < 0) continue
      displayModel.append({
        itemId: "dmenu." + i,
        kind: "dmenu",
        icon: icon,
        iconFont: "",
        appIcon: "",
        appId: "",
        label: label,
        target: "",
        detail: detail,
        path: "",
        childCount: 0,
        action: "",
        provider: "",
        score: i,
        section: ""
      })
    }

    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  function rebuildDisplay() {
    if (root.dmenuActive) {
      root.rebuildDmenuDisplay()
      return
    }

    displayModel.clear()

    if (!root.rowsLoaded) return

    var active = root.item(root.activeMenu) ? root.activeMenu : "root"
    root.activeMenu = active
    var rows = []
    var query = root.filterText.trim()
    root.searchDivider = false

    if (query) {
      var currentRows = []
      var drilldownRows = []

      for (var i = 0; i < root.itemOrder.length; i++) {
        var entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "root") continue
        if (!root.isDescendantOf(entry.id, active)) continue
        if (!root.matchesQuery(entry, query)) continue

        var detail = root.parentPathFor(entry.id)
        var row = root.displayRow(entry, detail, root.searchScore(entry, query))
        if (entry.parent === active) currentRows.push(row)
        else drilldownRows.push(row)
      }

      var searchSort = function(a, b) {
        if (a.score !== b.score) return a.score - b.score
        return a.path.localeCompare(b.path)
      }

      currentRows.sort(searchSort)
      drilldownRows.sort(searchSort)
      root.searchDivider = currentRows.length > 0 && drilldownRows.length > 0
      if (root.searchDivider) {
        for (var d = 0; d < drilldownRows.length; d++) drilldownRows[d].section = "drilldown"
      }
      rows = currentRows.concat(drilldownRows)
    } else {
      for (var j = 0; j < root.itemOrder.length; j++) {
        var child = root.item(root.itemOrder[j])
        if (!child || child.parent !== active) continue
        if (!root.isVisible(child)) continue
        rows.push(root.displayRow(child, child.description, child.order))
      }

      // DesktopEntries can reorder its values when an application starts.
      // Keep the Apps menu alphabetical independently of provider refreshes.
      if (active === "apps") {
        rows.sort(function(a, b) {
          var aLabel = String(a.label || "").toLowerCase()
          var bLabel = String(b.label || "").toLowerCase()
          if (aLabel < bLabel) return -1
          if (aLabel > bLabel) return 1
          var aId = String(a.itemId || "")
          var bId = String(b.itemId || "")
          if (aId < bId) return -1
          if (aId > bId) return 1
          return 0
        })
      }
    }

    for (var k = 0; k < rows.length; k++) displayModel.append(rows[k])
    layoutSerial += 1

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) root.revealCursor()
    })
  }

  // Contain alone parks the cursor row flush with the viewport edge, hiding
  // the neighbor entirely and losing the fold affordance. Keep the next
  // hidden row peeking past the cursor in the direction of travel.
  function revealCursor() {
    if (displayModel.count === 0) return
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)

    var item = resultList.itemAtIndex(root.selectedIndex)
    if (!item) return

    var reach = root.rowPeek + root.rowSpacing
    if (root.selectedIndex < displayModel.count - 1) {
      var maxY = Math.max(resultList.originY, resultList.originY + resultList.contentHeight - resultList.height)
      var overhang = item.y + item.height + reach - (resultList.contentY + resultList.height)
      if (overhang > 0) resultList.contentY = Math.min(resultList.contentY + overhang, maxY)
    }
    if (root.selectedIndex > 0) {
      var underhang = resultList.contentY - (item.y - reach)
      if (underhang > 0) resultList.contentY = Math.max(resultList.contentY - underhang, resultList.originY)
    }
  }

  function select(delta) {
    if (displayModel.count === 0) return

    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    revealCursor()
  }

  function setFilter(nextFilter) {
    panel.freezeCardTop()
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = root.mode !== "input"
    root.disarmPointer()
    if (!root.dmenuActive && root.filterText.trim()) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory, fromPointer) {
    panel.freezeCardTop()
    if (!root.item(id)) id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    if (fromPointer) pointerGate.allowInitialSample()
    else root.disarmPointer()
    root.rebuildDisplay()
    root.invalidateVolatileProvider(id)
    root.loadProviderForMenu(id)
  }

  function goBack() {
    if (root.activeMenu === "root") return false

    if (root.navStack.length > 0) {
      var previous = root.navStack[root.navStack.length - 1]
      root.navStack = root.navStack.slice(0, root.navStack.length - 1)
      root.setActiveMenu(previous, false)
      return true
    }

    var active = root.item(root.activeMenu)
    root.setActiveMenu((active && active.parent) ? active.parent : "root", false)
    return true
  }

  function activateIndex(index, fromPointer) {
    if (root.deleteConfirmOpen) return
    if (root.dmenuActive) {
      if (root.mode === "input") {
        root.applyDmenuSelection(root.filterText)
        return
      }
      if (index < 0 || index >= displayModel.count) return
      var picked = displayModel.get(index)
      root.applyDmenuSelection(picked.detail ? picked.label + "\t" + picked.detail : picked.label)
      return
    }

    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    if (row.itemId === "style.menu-look") {
      root.setActiveMenu("style.menu-look", true, fromPointer)
      return
    }
    if (row.kind === "menu" || row.kind === "link") {
      root.setActiveMenu(row.target || row.itemId, true, fromPointer)
    } else if (row.kind === "app") {
      var appId = row.appId
      var label = row.label
      applySerial = requestSerial
      opened = false
      filterText = ""
      if (root.appLibrary) root.appLibrary.launch(appId, label)
    } else {
      root.applySelected(row.itemId, row.action)
    }
  }

  function requestDeleteSelected() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return
    var row = displayModel.get(root.selectedIndex)
    if (!row || row.kind !== "app") return
    root.deleteTarget = { appId: row.appId, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmDelete() {
    var target = root.deleteTarget
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    if (!target) return
    root.cancel()
    if (root.appLibrary) root.appLibrary.remove(target.appId, target.label)
  }

  function applyDmenuSelection(value) {
    applySerial = requestSerial
    opened = false
    filterText = ""
    root.finishRequest(value)
  }

  function applySelected(id, action) {
    if (!id) { cancel(); return }

    applySerial = requestSerial
    opened = false
    filterText = ""
    root.runAction(action)
  }

  function cancel() {
    if (root.dmenuActive) root.finishRequest(null)
    opened = false
    filterText = ""
  }

  function openExistingMenu(initialMenu) {
    requestSerial += 1
    mode = "menu"
    requestActive = false
    selectionFile = ""
    doneFile = ""
    activeMenu = root.item(initialMenu) ? initialMenu : "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = true
    root.disarmPointer()
    root.evaluateGuards()
    opened = true
    rebuildDisplay()
    invalidateVolatileProvider(activeMenu)
    loadProviderForMenu(activeMenu)
    // The shell may start before first-install packages have finished placing
    // their icons. Refresh here even when the desktop entry list did not change.
    if (root.appLibrary) root.appLibrary.refreshIcons()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function openDmenu(payload) {
    requestSerial += 1
    mode = payload.mode === "input" ? "input" : "select"
    dmenuPrompt = String(payload.prompt || (mode === "input" ? "Input" : "Select")).slice(0, root.maxDmenuStringLen)
    dmenuOptions = (Array.isArray(payload.options) ? payload.options : [])
      .slice(0, root.maxDmenuOptions)
      .map(function(o) { return String(o).slice(0, root.maxDmenuStringLen) })
    selectionFile = String(payload.selectionFile || "")
    doneFile = String(payload.doneFile || "")
    requestActive = !!doneFile
    dmenuWidth = Math.max(1, Number(payload.width || 300))
    dmenuMaxHeight = Math.max(0, Number(payload.maxHeight || 0))
    activeMenu = "root"
    navStack = []
    filterText = ""
    selectedIndex = 0
    cursorActive = mode !== "input"
    root.disarmPointer()
    opened = true
    rebuildDisplay()

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  ListModel { id: displayModel }

  // ----------------------------------------------------------- route surface
  //
  // The menu is opened through the standard plugin lifecycle:
  // `omarchy-shell shell summon omarchy.menu '{"menu":"system"}'`.
  // Callers may pass a real id (`system`, `setup.power`) or an alias declared
  // in JSONC (`power`, `reminder-set`). Unknown strings fall through to the
  // id-as-route behavior so misspellings still attempt to open the literal id.
  function resolveRoute(input) {
    return MenuModel.resolveRoute(root.items, root.itemOrder, input)
  }

  function openRoute(initialMenu) {
    var id = root.resolveRoute(initialMenu)
    var entry = root.items[id]
    // If the resolved id is an action (i.e. the user invoked an alias for
    // a leaf, e.g. `omarchy menu summon screenrecord-stop`), run it directly
    // instead of opening an action with no children.
    if (entry && entry.kind === "action" && entry.action) {
      root.cancel()
      root.runAction(entry.action)
      return "ok"
    }
    // If it's a link (a redirect to another menu), follow the link.
    if (entry && entry.kind === "link" && entry.target) id = entry.target
    root.pendingInitialMenu = id
    root.openExistingMenu(id)
    return "ok"
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property string collected: ""
    property string pendingScript: ""
    property int revision: 0
    // The script goes over stdin, never argv (see cappedRunnerScript).
    stdinEnabled: true
    onStarted: {
      write(root.framedPayload(providerProc.pendingScript))
      providerProc.pendingScript = ""
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (providerProc.collected.length < root.maxProcOutputBytes)
          providerProc.collected += data + "\n"
      }
    }
    onExited: function(exitCode) {
      // cappedRunnerScript exits non-zero on overflow (3) or a failed
      // producer (4); discard the stream in either case.
      if (exitCode === 0 && providerProc.revision === root.providerRevision) {
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
        if (root.filterText.trim()) root.loadProvidersForSearch()
      }
      root.startNextProvider()
    }
  }

  Process {
    id: resultProc
    property string pendingValue: ""
    property bool hasSelection: false
    // The selected/typed value goes over stdin, never argv: dmenu input is
    // user text and /proc/<pid>/cmdline is world-readable.
    stdinEnabled: true
    onStarted: {
      if (resultProc.hasSelection) write(root.framedPayload(resultProc.pendingValue))
      resultProc.pendingValue = ""
    }
    onExited: {
      if (root.applySerial === root.requestSerial)
        root.opened = false
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() {
      if (root.providersLoaded["apps"]) root.mergeAppRows()
    }
  }

  // The two JSONC sources - the packaged default and the user extension at
  // ~/.config/omarchy/extensions/omarchy-menu.jsonc - are read through the
  // same bounded, deadlined, O_NOFOLLOW helper as everything else (upstream
  // reads them with an uncapped FileView). The FileViews below stay only as
  // change notifiers so live edits still apply without a restart.
  Process {
    id: defaultMenuReadProc
    stdout: StdioCollector { id: defaultMenuOut; waitForEnd: true }
    onExited: function (code) {
      root.defaultMenuItems = root.parseMenuJsonc(code === 0 ? defaultMenuOut.text : "")
      root.rebuildItemsFromSources()
    }
  }
  Process {
    id: userMenuReadProc
    stdout: StdioCollector { id: userMenuOut; waitForEnd: true }
    onExited: function (code) {
      root.userMenuItems = root.parseMenuJsonc(code === 0 ? userMenuOut.text : "")
      root.rebuildItemsFromSources()
    }
  }
  function readDefaultMenu() { root.readBounded(defaultMenuReadProc, root.defaultMenuPath, root.maxMenuFileBytes) }
  function readUserMenu() { root.readBounded(userMenuReadProc, root.userMenuPath, root.maxMenuFileBytes) }

  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readDefaultMenu()
  }
  FileView {
    id: userMenuFile
    path: root.userMenuPath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.readUserMenu()
  }

  // ---------------------------------------------------------------- guards
  //
  // `when:` (visibility) and `checked:` (✓ marker) are bash expressions the
  // shell wasn't allowed to evaluate before the perf rewrite. Now the shell
  // batches them into one bash subprocess per (re)load so the open path
  // never has to wait on them.

  property var whenResults: ({})       // id → true|false (allow visibility)
  property var checkedResults: ({})    // id → true|false (show ✓)
  property bool guardsPending: false

  function evaluateGuards() {
    // Process ignores a command change while it is running, and `collected`
    // belongs to the run in flight, so a second evaluation cannot overwrite
    // the first: it would throw away the lines already read and never start.
    // The surviving tail then lands as the whole answer, and every id lost
    // with it goes back to showing, since a `when:` only hides on an explicit
    // false. Wait for the run in flight and evaluate once it lands instead.
    if (guardProc.running) {
      root.guardsPending = true
      return
    }
    root.guardsPending = false

    // Aggregate bounds before anything is spawned: the per-field caps still
    // allow 6000 items x 4 KiB of `when:`/`checked:`, which is a multi-megabyte
    // batch. Fail closed on either bound - the same thing `!script` does, and
    // the same thing the exit-code handlers do for a truncated stream - rather
    // than run a partial set of guards and treat it as a complete answer.
    var guardCount = 0
    var guardIds = Object.keys(root.items || {})
    for (var gi = 0; gi < guardIds.length; gi++) {
      var guarded = root.items[guardIds[gi]]
      if (!guarded) continue
      if (guarded.when) guardCount += 1
      if (guarded.checked) guardCount += 1
    }

    var script = MenuModel.guardScript(root.items)
    if (!script || guardCount > root.maxGuardCount || root.scriptTooBig(script)) {
      root.whenResults = ({})
      root.checkedResults = ({})
      return
    }
    guardProc.collected = ""
    guardProc.pendingScript = script
    guardProc.command = root.bashCappedCommand()
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    property string pendingScript: ""
    // The guard batch goes over stdin, never argv (see cappedRunnerScript).
    stdinEnabled: true
    onStarted: {
      write(root.framedPayload(guardProc.pendingScript))
      guardProc.pendingScript = ""
    }
    stdout: SplitParser {
      onRead: function(data) {
        if (guardProc.collected.length < root.maxProcOutputBytes)
          guardProc.collected += data + "\n"
      }
    }
    onExited: function(exitCode, exitStatus) {
      // A batch that was killed rather than finished has only told us about
      // the rows it reached, and a row whose `when:` went unanswered shows.
      // Keep the last complete set rather than let a half-read one through.
      // A signal leaves the exit code at 0, so the status is what tells us.
      var lines = guardProc.collected.split("\n")
      // Non-zero exit (incl. the runner's overflow/deadline codes) or a
      // result set larger than the cap: fail closed - keep the previous
      // guard answers rather than accept a truncated decision set.
      if (exitCode !== 0 || exitStatus !== 0 || lines.length > root.maxGuardLines) {
        if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
        return
      }

      var nextWhen = ({})
      var nextChecked = ({})
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim().slice(0, root.maxFieldLen)
        if (!line) continue
        var colon = line.lastIndexOf(":")
        if (colon < 0) continue
        var value = line.substring(colon + 1) === "1"
        var rest = line.substring(0, colon)
        var tagAt = rest.lastIndexOf(":")
        if (tagAt < 0) continue
        var id = rest.substring(0, tagAt)
        var tag = rest.substring(tagAt + 1)
        if (tag === "w") nextWhen[id] = value
        else if (tag === "c") nextChecked[id] = value
      }
      root.whenResults = nextWhen
      root.checkedResults = nextChecked
      if (root.opened) root.rebuildDisplay()
      // Run the evaluation that had to stand aside. Deferred by a turn so the
      // process is settled before its command is set again.
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }
  PanelWindow {
    id: panel
    visible: root.opened && root.rowsLoaded
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // The card opens centered exactly as always. The first search keystroke
    // or submenu move freezes the top line where it currently sits — from
    // then on the card grows and shrinks downward instead of re-centering
    // on every resize, which made the menu jump around. The rows height is
    // frozen at the same moment, so the starting menu also caps how tall the
    // card may grow from there. Closing unfreezes both.
    property int cardTop: -1
    property int maxRowsHeight: -1
    readonly property int centeredTop: Math.max(Style.gapsOut, Math.round((height - root.cardHeight * root.cfgScale) / 2))
    readonly property int effectiveCardTop: cardTop >= 0 ? cardTop : centeredTop
    function freezeCardTop() {
      if (visible && cardTop < 0) {
        cardTop = effectiveCardTop
        maxRowsHeight = root.visibleRowsHeight
      }
    }
    onVisibleChanged: if (!visible) { cardTop = -1; maxRowsHeight = -1 }

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.cancel()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: Math.min(root.cardHeight, (panel.height - Style.gapsOut - panel.effectiveCardTop) / root.cfgScale)
      radius: root.cornerRadius
      anchors.horizontalCenter: parent.horizontalCenter
      y: panel.effectiveCardTop
      scale: root.cfgScale
      transformOrigin: Item.Top
      color: root.cfgTransparency > 0 ? Util.alpha(root.background, 1 - root.cfgTransparency / 100) : root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.deleteConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }

          // In the Menu Look editor the sliders own the pointer; only wire
          // up the ways back so typing/arrows don't leak into a filter.
          if (root.activeMenu === "style.menu-look") {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
                || event.key === Qt.Key_Left) {
              root.goBack()
              event.accepted = true
            }
            return
          }

          if (event.key === Qt.Key_Delete) {
            root.requestDeleteSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.cancel()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && !root.filterText) {
            root.goBack()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right) {
            if (root.dmenuActive) {
              if (root.mode === "input") root.applyDmenuSelection(root.filterText)
              else if (displayModel.count > 0) root.activateIndex(root.cursorActive ? root.selectedIndex : 0)
            } else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: deleteConfirm

          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Do you want to uninstall " + ((root.deleteTarget && root.deleteTarget.label) || "") + "?"
          confirmText: "Uninstall"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelDelete()
          onConfirmed: root.confirmDelete()
        }
      }

      MenuLookEditor {
        id: lookEditor
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        visible: root.activeMenu === "style.menu-look"
        menu: root
        onDone: root.goBack()
      }

      Column {
        visible: root.activeMenu !== "style.menu-look"
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || (root.dmenuActive ? (root.dmenuPrompt + "…") : ((root.item(root.activeMenu) ? (root.item(root.activeMenu).title || root.item(root.activeMenu).label) : "Go") + "…"))
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

        }

        Item {
          width: parent.width
          height: root.visibleRowsHeight

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: root.rowSpacing
            boundsBehavior: Flickable.StopAtBounds

            section.property: "section"
            section.criteria: ViewSection.FullString
            section.delegate: Item {
              required property string section

              width: ListView.view.width
              height: section === "drilldown" ? root.dividerHeight : 0
              visible: section === "drilldown"

              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.spacing.hairline
                color: Util.alpha(root.foreground, 0.2)
              }
            }

            delegate: BorderSurface {
              id: row
              required property int index
              required property string itemId
              required property string kind
              required property string icon
              required property string iconFont
              required property string appIcon
              required property string appId
              required property string label
              required property string target
              required property string detail
              required property string path
              required property string action
              required property int childCount

              readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
              readonly property bool isApp: row.kind === "app"
              readonly property bool hasIcon: row.icon.length > 0 || row.isApp

              width: ListView.view.width
              height: root.rowHeightForDetail(row.detail)
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Rectangle {
                visible: false
                width: Style.space(4)
                height: parent.height - Style.space(18)
                radius: Math.min(root.cornerRadius, Style.space(4))
                color: root.selectedBackground
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: iconText
                textFormat: Text.PlainText
                visible: row.hasIcon && !row.isApp
                text: row.icon
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: row.iconFont.length > 0 ? row.iconFont : root.fontFamily
                font.pixelSize: Style.font.iconLarge
                width: Style.space(36)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Image {
                id: appIconImage
                visible: row.isApp
                width: Style.font.iconLarge
                height: Style.font.iconLarge
                fillMode: Image.PreserveAspectFit
                // Decode at physical pixels — a logical-size decode leaves
                // PNG icons upscaled and blurry on HiDPI displays.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: row.isApp && root.appLibrary ? root.appLibrary.iconSource(row.appIcon) : ""
                asynchronous: true
                anchors.left: parent.left
                anchors.leftMargin: root.rowReservedBorderLeft + Style.space(8) + (Style.space(36) - width) / 2
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
              }

              Column {
                id: contentColumn
                anchors.left: row.hasIcon ? iconText.right : parent.left
                anchors.leftMargin: row.hasIcon ? Style.space(6) : root.rowReservedBorderLeft + Style.space(18)
                anchors.right: trail.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  id: labelText
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.label
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Medium
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: row.detail
                  visible: (root.filterText || row.kind === "dmenu") && row.detail.length > 0
                  color: root.foreground
                  opacity: 0.52
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              Row {
                id: trail
                width: Style.space(14)
                anchors.right: parent.right
                anchors.rightMargin: root.rowReservedBorderRight + Style.space(8)
                y: contentColumn.y + labelText.y + (labelText.height - height) / 2
                spacing: 0

                Text {
                  textFormat: Text.PlainText
                  visible: false
                  text: row.childCount
                  color: root.foreground
                  opacity: 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: row.kind === "menu" || row.kind === "link" ? "›" : ""
                  color: row.hasCursor ? root.selectedText : root.foreground
                  opacity: row.kind === "menu" || row.kind === "link" ? 0.36 : 0
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.weight: Font.Normal
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                id: mouseArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectFromPointer(row.index, row, {
                  x: mouseArea.mouseX,
                  y: mouseArea.mouseY
                })
                onPositionChanged: function(mouse) {
                  root.selectFromPointer(row.index, row, mouse)
                }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                  root.activateIndex(row.index, true)
                }
              }
            }
          }

          // Scroll scrims. The clipped row already marks the fold at rest;
          // these keep both edges honest once the list has been scrolled,
          // when content hides above the card top as well as below. Strength
          // tracks the distance still hidden past each edge rather than
          // animating on a clock, so a programmatic jump — wrapping from the
          // last row back to the first — lands with the fade already applied.
          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: resultList.contentHeight > resultList.height
              ? Math.max(0, Math.min(1, (resultList.contentY - resultList.originY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: root.background }
              GradientStop { position: 1; color: Util.alpha(root.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: resultList.contentHeight > resultList.height
              ? Math.max(0, Math.min(1, (resultList.originY + resultList.contentHeight - resultList.height - resultList.contentY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.background, 0) }
              GradientStop { position: 1; color: root.background }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0 && root.mode !== "input"

            Text {
              text: "󰈉"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }

            Text {
              textFormat: Text.PlainText
              text: root.filterText ? "No matches for “" + root.filterText + "”" : "Nothing here yet"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: Style.space(320)
            }
          }
        }

        Item {
          width: parent.width
          height: 0
        }
      }
    }
  }
}
