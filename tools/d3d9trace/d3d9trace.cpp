// d3d9trace — a pass-through Direct3D 9 "spy" for osxEQEmu.
//
// It is loaded INSTEAD of d3d9.dll (dropped next to eqgame.exe, d3d9=n,b), loads the
// real d3d9.dll from the system directory and forwards everything to it unchanged.
// On the way it records what the game asks of Direct3D 9, so that a future
// Direct3D 9 -> Metal layer (e.g. a d3d9 front end for DXMT) can be scoped to what
// RoF2 really uses instead of all of Direct3D 9:
//   - every IDirect3D9 / IDirect3DDevice9 method: call counts (total, per frame);
//   - device creation / reset parameters, formats probed (CheckDeviceFormat);
//   - draws: primitive types, sizes, fixed-function vs shaders, pre-transformed;
//   - render / texture-stage / sampler states and the values used;
//   - resources: texture formats, buffer usages, Lock flags;
//   - every vertex/pixel shader, dumped as bytecode (shaders/*.bin) with its model.
// Output (OSXEQEMU_TRACE_DIR, else .\d3d9-trace): summary.txt (rewritten every 30 s and
// at exit, ends with a "work list" for the translator), timeline.txt (one line per
// 5 s: fps, draws, calls — shows the scenes), events.txt (first time each new
// feature/format is seen, with frame number), shaders/.
//
// Mechanism: the vtables of the real objects are patched in place. Every entry
// points to a tiny counting stub (lock inc; jmp to the original); the methods we
// analyse in detail get a C++ hook instead, which counts too, then calls the
// original. Nothing is changed in what the game sends or receives.
//
// Only Daybreak-independent code here: no game file is read or modified.
// Build: tools/d3d9trace/build.sh (i686-w64-mingw32-g++). MIT, like osxEQEmu.

#define CINTERFACE
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "trace_tables.h"

// ---------------------------------------------------------------------------------
// method tables (generated) + compile-time check that our order matches d3d9.h
enum {
#define X(m) DEV_##m,
    TRACE_DEV_METHODS(X)
#undef X
    DEV_N
};
enum {
#define X(m) D3D_##m,
    TRACE_D3D_METHODS(X)
#undef X
    D3D_N
};
static_assert(DEV_N == TRACE_DEV_COUNT && D3D_N == TRACE_D3D_COUNT, "method count");
#define X(m) static_assert(offsetof(IDirect3DDevice9Vtbl, m) == DEV_##m * sizeof(void *), #m);
TRACE_DEV_METHODS(X)
#undef X
#define X(m) static_assert(offsetof(IDirect3D9Vtbl, m) == D3D_##m * sizeof(void *), #m);
TRACE_D3D_METHODS(X)
#undef X
static_assert(offsetof(IDirect3DVertexBuffer9Vtbl, Lock) == 11 * sizeof(void *), "VB Lock");
static_assert(offsetof(IDirect3DIndexBuffer9Vtbl, Lock) == 11 * sizeof(void *), "IB Lock");
static_assert(offsetof(IDirect3DTexture9Vtbl, LockRect) == 19 * sizeof(void *), "Tex LockRect");

static const char *const g_dev_names[] = {
#define X(m) #m,
    TRACE_DEV_METHODS(X)
#undef X
};
static const char *const g_d3d_names[] = {
#define X(m) #m,
    TRACE_D3D_METHODS(X)
#undef X
};

extern "C" {
volatile LONG g_dev_count[TRACE_DEV_COUNT];
void *g_dev_orig[TRACE_DEV_COUNT];
extern void *g_dev_stubs[TRACE_DEV_COUNT];
volatile LONG g_d3d_count[TRACE_D3D_COUNT];
void *g_d3d_orig[TRACE_D3D_COUNT];
extern void *g_d3d_stubs[TRACE_D3D_COUNT];
void *g_fwd_ptr[TRACE_FWD_COUNT];
}
// (the counting stubs and export forwarders are asm blocks in trace_tables.h)

// ---------------------------------------------------------------------------------
// state
static CRITICAL_SECTION g_cs;
static HMODULE g_real;
static std::string g_dir;
static LARGE_INTEGER g_qpf, g_t0;
static bool g_dev_hooked, g_d3d_hooked, g_vb_hooked, g_ib_hooked, g_tex_hooked;
static void *g_vb_lock_orig, *g_ib_lock_orig, *g_tex_lock_orig;

struct ValueStats {                       // per state: how often set, which values
    uint64_t sets = 0;
    std::map<DWORD, uint64_t> values;     // capped at 16 distinct
    bool more = false;
    void add(DWORD v) {
        sets++;
        auto it = values.find(v);
        if (it != values.end()) it->second++;
        else if (values.size() < 16) values[v] = 1;
        else more = true;
    }
};
static ValueStats g_rs[256], g_tss[33], g_samp[14];

struct DrawStats { uint64_t calls = 0, prims = 0; };
static DrawStats g_draw[4][7];            // [DP, DIP, DPUP, DIPUP][primitive type]
static uint64_t g_draw_mode[2][2];        // [VS shader?][PS shader?]
static uint64_t g_draw_rhw, g_draw_total;
static bool g_cur_vs, g_cur_ps, g_cur_decl_rhw, g_cur_use_decl;
static DWORD g_cur_fvf;
static std::map<void *, bool> g_decl_rhw;

static std::map<std::string, uint64_t> g_decls, g_textures, g_buffers, g_shader_models, g_formats_probed,
    g_present_params;
// Hot paths (called thousands of times per frame) only count numbers; text is built
// when the summary is written.
static std::map<DWORD, uint64_t> g_fvf;
static std::map<DWORD, uint64_t> g_lock_flags[3];          // [VB, IB, texture (bit 31: sub-rect)]
static uint32_t g_draw_seen[4][7];                          // bit (vs*4 + ps*2 + rhw): event already logged
static uint32_t g_stage_seen;
static std::set<uint32_t> g_shader_hashes;
static uint64_t g_shader_count[2];

static uint64_t g_frames, g_frame_draws, g_frame_draws_max;
static uint64_t g_frame_ticks_total, g_frame_ticks_max;
static LARGE_INTEGER g_last_present, g_last_timeline, g_last_summary;
static uint64_t g_tl_frames, g_tl_draws;
static LONG g_tl_calls_base;
static std::set<std::string> g_seen_events;

// ---------------------------------------------------------------------------------
// names
static const char *rs_name(DWORD s) {
    switch (s) {
#define N(v, n) case v: return n;
    N(7,"ZENABLE") N(8,"FILLMODE") N(9,"SHADEMODE") N(14,"ZWRITEENABLE") N(15,"ALPHATESTENABLE")
    N(16,"LASTPIXEL") N(19,"SRCBLEND") N(20,"DESTBLEND") N(22,"CULLMODE") N(23,"ZFUNC")
    N(24,"ALPHAREF") N(25,"ALPHAFUNC") N(26,"DITHERENABLE") N(27,"ALPHABLENDENABLE")
    N(28,"FOGENABLE") N(29,"SPECULARENABLE") N(34,"FOGCOLOR") N(35,"FOGTABLEMODE")
    N(36,"FOGSTART") N(37,"FOGEND") N(38,"FOGDENSITY") N(48,"RANGEFOGENABLE")
    N(52,"STENCILENABLE") N(53,"STENCILFAIL") N(54,"STENCILZFAIL") N(55,"STENCILPASS")
    N(56,"STENCILFUNC") N(57,"STENCILREF") N(58,"STENCILMASK") N(59,"STENCILWRITEMASK")
    N(60,"TEXTUREFACTOR") N(128,"WRAP0") N(129,"WRAP1") N(130,"WRAP2") N(131,"WRAP3")
    N(132,"WRAP4") N(133,"WRAP5") N(134,"WRAP6") N(135,"WRAP7") N(136,"CLIPPING")
    N(137,"LIGHTING") N(139,"AMBIENT") N(140,"FOGVERTEXMODE") N(141,"COLORVERTEX")
    N(142,"LOCALVIEWER") N(143,"NORMALIZENORMALS") N(145,"DIFFUSEMATERIALSOURCE")
    N(146,"SPECULARMATERIALSOURCE") N(147,"AMBIENTMATERIALSOURCE") N(148,"EMISSIVEMATERIALSOURCE")
    N(151,"VERTEXBLEND") N(152,"CLIPPLANEENABLE") N(154,"POINTSIZE") N(155,"POINTSIZE_MIN")
    N(156,"POINTSPRITEENABLE") N(157,"POINTSCALEENABLE") N(158,"POINTSCALE_A") N(159,"POINTSCALE_B")
    N(160,"POINTSCALE_C") N(161,"MULTISAMPLEANTIALIAS") N(162,"MULTISAMPLEMASK")
    N(163,"PATCHEDGESTYLE") N(165,"DEBUGMONITORTOKEN") N(166,"POINTSIZE_MAX")
    N(167,"INDEXEDVERTEXBLENDENABLE") N(168,"COLORWRITEENABLE") N(170,"TWEENFACTOR")
    N(171,"BLENDOP") N(172,"POSITIONDEGREE") N(173,"NORMALDEGREE") N(174,"SCISSORTESTENABLE")
    N(175,"SLOPESCALEDEPTHBIAS") N(176,"ANTIALIASEDLINEENABLE") N(178,"MINTESSELLATIONLEVEL")
    N(179,"MAXTESSELLATIONLEVEL") N(180,"ADAPTIVETESS_X") N(181,"ADAPTIVETESS_Y")
    N(182,"ADAPTIVETESS_Z") N(183,"ADAPTIVETESS_W") N(184,"ENABLEADAPTIVETESSELLATION")
    N(185,"TWOSIDEDSTENCILMODE") N(186,"CCW_STENCILFAIL") N(187,"CCW_STENCILZFAIL")
    N(188,"CCW_STENCILPASS") N(189,"CCW_STENCILFUNC") N(190,"COLORWRITEENABLE1")
    N(191,"COLORWRITEENABLE2") N(192,"COLORWRITEENABLE3") N(193,"BLENDFACTOR")
    N(194,"SRGBWRITEENABLE") N(195,"DEPTHBIAS") N(206,"SEPARATEALPHABLENDENABLE")
    N(207,"SRCBLENDALPHA") N(208,"DESTBLENDALPHA") N(209,"BLENDOPALPHA")
#undef N
    default: return nullptr;
    }
}
static const char *tss_name(DWORD s) {
    static const char *n[33] = {nullptr, "COLOROP", "COLORARG1", "COLORARG2", "ALPHAOP", "ALPHAARG1",
        "ALPHAARG2", "BUMPENVMAT00", "BUMPENVMAT01", "BUMPENVMAT10", "BUMPENVMAT11", "TEXCOORDINDEX",
        nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
        "BUMPENVLSCALE", "BUMPENVLOFFSET", "TEXTURETRANSFORMFLAGS", nullptr, "COLORARG0", "ALPHAARG0",
        "RESULTARG", nullptr, nullptr, nullptr, "CONSTANT"};
    return s < 33 ? n[s] : nullptr;
}
static const char *samp_name(DWORD s) {
    static const char *n[14] = {nullptr, "ADDRESSU", "ADDRESSV", "ADDRESSW", "BORDERCOLOR", "MAGFILTER",
        "MINFILTER", "MIPFILTER", "MIPMAPLODBIAS", "MAXMIPLEVEL", "MAXANISOTROPY", "SRGBTEXTURE",
        "ELEMENTINDEX", "DMAPOFFSET"};
    return s < 14 ? n[s] : nullptr;
}
static const char *texop_name(DWORD v) {             // D3DTEXTUREOP, for COLOROP/ALPHAOP
    static const char *n[] = {nullptr, "DISABLE", "SELECTARG1", "SELECTARG2", "MODULATE", "MODULATE2X",
        "MODULATE4X", "ADD", "ADDSIGNED", "ADDSIGNED2X", "SUBTRACT", "ADDSMOOTH", "BLENDDIFFUSEALPHA",
        "BLENDTEXTUREALPHA", "BLENDFACTORALPHA", "BLENDTEXTUREALPHAPM", "BLENDCURRENTALPHA", "PREMODULATE",
        "MODULATEALPHA_ADDCOLOR", "MODULATECOLOR_ADDALPHA", "MODULATEINVALPHA_ADDCOLOR",
        "MODULATEINVCOLOR_ADDALPHA", "BUMPENVMAP", "BUMPENVMAPLUMINANCE", "DOTPRODUCT3", "MULTIPLYADD", "LERP"};
    return v < sizeof(n) / sizeof(n[0]) ? n[v] : nullptr;
}
static std::string fmt_name(DWORD f) {
    switch (f) {
#define F(v, n) case v: return n;
    F(0,"UNKNOWN") F(20,"R8G8B8") F(21,"A8R8G8B8") F(22,"X8R8G8B8") F(23,"R5G6B5") F(24,"X1R5G5B5")
    F(25,"A1R5G5B5") F(26,"A4R4G4B4") F(27,"R3G3B2") F(28,"A8") F(29,"A8R3G3B2") F(30,"X4R4G4B4")
    F(31,"A2B10G10R10") F(32,"A8B8G8R8") F(33,"X8B8G8R8") F(34,"G16R16") F(35,"A2R10G10B10")
    F(36,"A16B16G16R16") F(40,"A8P8") F(41,"P8") F(50,"L8") F(51,"A8L8") F(52,"A4L4") F(60,"V8U8")
    F(61,"L6V5U5") F(62,"X8L8V8U8") F(63,"Q8W8V8U8") F(64,"V16U16") F(67,"A2W10V10U10")
    F(70,"D16_LOCKABLE") F(71,"D32") F(73,"D15S1") F(75,"D24S8") F(77,"D24X8") F(79,"D24X4S4")
    F(80,"D16") F(81,"L16") F(82,"D32F_LOCKABLE") F(83,"D24FS8") F(100,"VERTEXDATA")
    F(101,"INDEX16") F(102,"INDEX32") F(110,"Q16W16V16U16") F(111,"R16F") F(112,"G16R16F")
    F(113,"A16B16G16R16F") F(114,"R32F") F(115,"G32R32F") F(116,"A32B32G32R32F") F(117,"CxV8U8")
#undef F
    }
    if (f > 0xFFFF) {                                // FOURCC: DXT1..5, INTZ, NULL, ATI2…
        char c[5] = {(char)(f & 0xFF), (char)((f >> 8) & 0xFF), (char)((f >> 16) & 0xFF),
                     (char)((f >> 24) & 0xFF), 0};
        bool printable = true;
        for (int i = 0; i < 4; i++) printable &= c[i] >= 32 && c[i] < 127;
        if (printable) return c;
    }
    char b[24];
    snprintf(b, sizeof b, "fmt%lu", (unsigned long)f);
    return b;
}
static const char *pool_name(DWORD p) {
    static const char *n[] = {"DEFAULT", "MANAGED", "SYSTEMMEM", "SCRATCH"};
    return p < 4 ? n[p] : "?";
}
static std::string usage_str(DWORD u) {
    static const struct { DWORD bit; const char *n; } b[] = {
        {0x1, "RENDERTARGET"}, {0x2, "DEPTHSTENCIL"}, {0x8, "WRITEONLY"}, {0x10, "SOFTWAREPROCESSING"},
        {0x20, "DONOTCLIP"}, {0x40, "POINTS"}, {0x80, "RTPATCHES"}, {0x100, "NPATCHES"},
        {0x200, "DYNAMIC"}, {0x400, "AUTOGENMIPMAP"}, {0x10000, "QUERY_*"}};
    std::string s;
    for (auto &e : b)
        if (u & e.bit) { if (!s.empty()) s += "|"; s += e.n; }
    return s.empty() ? "0" : s;
}
static std::string lock_str(DWORD f) {
    static const struct { DWORD bit; const char *n; } b[] = {
        {0x10, "READONLY"}, {0x800, "NOSYSLOCK"}, {0x1000, "NOOVERWRITE"}, {0x2000, "DISCARD"},
        {0x4000, "DONOTWAIT"}, {0x8000, "NO_DIRTY_UPDATE"}};
    std::string s;
    for (auto &e : b)
        if (f & e.bit) { if (!s.empty()) s += "|"; s += e.n; }
    return s.empty() ? "0" : s;
}
static const char *prim_name(int t) {
    static const char *n[] = {"?", "POINTLIST", "LINELIST", "LINESTRIP", "TRIANGLELIST", "TRIANGLESTRIP",
                              "TRIANGLEFAN"};
    return t >= 1 && t <= 6 ? n[t] : n[0];
}
static std::string fvf_str(DWORD fvf) {
    static const char *pos[] = {"", "XYZ", "XYZRHW", "XYZB1", "XYZB2", "XYZB3", "XYZB4", "XYZB5", "XYZW"};
    std::string s;
    DWORD p = (fvf & 0x400E) >> 1;
    if (fvf & 0x4000) p = 8;
    if (p < 9 && *pos[p]) s += pos[p];
    if (fvf & 0x10) s += "|NORMAL";
    if (fvf & 0x20) s += "|PSIZE";
    if (fvf & 0x40) s += "|DIFFUSE";
    if (fvf & 0x80) s += "|SPECULAR";
    char b[32];
    snprintf(b, sizeof b, "|TEX%lu", (unsigned long)((fvf >> 8) & 0xF));
    s += b;
    snprintf(b, sizeof b, " (0x%lx)", (unsigned long)fvf);
    return s + b;
}

// ---------------------------------------------------------------------------------
// output
static double secs_since_start() {
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)(t.QuadPart - g_t0.QuadPart) / (double)g_qpf.QuadPart;
}
static void append_file(const char *name, const std::string &line) {
    std::string p = g_dir + "\\" + name;
    FILE *f = fopen(p.c_str(), "ab");
    if (!f) return;
    fwrite(line.data(), 1, line.size(), f);
    fclose(f);
}
// First time a given feature/format is met: one line with frame + time (shows which
// scene needs what). Caller holds g_cs.
static void event_once(const std::string &key) {
    if (!g_seen_events.insert(key).second) return;
    char b[64];
    snprintf(b, sizeof b, "frame %-7llu %8.1fs  ", (unsigned long long)g_frames, secs_since_start());
    append_file("events.txt", std::string(b) + key + "\r\n");
}
static void bump(std::map<std::string, uint64_t> &m, const std::string &k) { m[k]++; }

// ---------------------------------------------------------------------------------
// vtable patching
static void patch_vtable(void **vtbl, int n, void **orig, void *const *repl) {
    DWORD old;
    if (!VirtualProtect(vtbl, n * sizeof(void *), PAGE_READWRITE, &old)) return;
    for (int i = 0; i < n; i++) {
        orig[i] = vtbl[i];
        vtbl[i] = repl[i];
    }
    VirtualProtect(vtbl, n * sizeof(void *), old, &old);
    FlushInstructionCache(GetCurrentProcess(), vtbl, n * sizeof(void *));
}
static void *patch_one(void **vtbl, int idx, void *hook) {
    DWORD old;
    if (!VirtualProtect(&vtbl[idx], sizeof(void *), PAGE_READWRITE, &old)) return nullptr;
    void *o = vtbl[idx];
    vtbl[idx] = hook;
    VirtualProtect(&vtbl[idx], sizeof(void *), old, &old);
    return o;
}
#define ORIG(T, idx) ((T)g_dev_orig[idx])
#define COUNT(idx) InterlockedIncrement(&g_dev_count[idx])

// ---------------------------------------------------------------------------------
// resource hooks (installed on the first object of each kind)
typedef HRESULT(WINAPI *PFN_BufLock)(void *, UINT, UINT, void **, DWORD);
typedef HRESULT(WINAPI *PFN_TexLock)(IDirect3DTexture9 *, UINT, D3DLOCKED_RECT *, const RECT *, DWORD);
static HRESULT WINAPI hook_vb_lock(void *self, UINT off, UINT size, void **data, DWORD flags) {
    EnterCriticalSection(&g_cs);
    g_lock_flags[0][flags]++;
    LeaveCriticalSection(&g_cs);
    return ((PFN_BufLock)g_vb_lock_orig)(self, off, size, data, flags);
}
static HRESULT WINAPI hook_ib_lock(void *self, UINT off, UINT size, void **data, DWORD flags) {
    EnterCriticalSection(&g_cs);
    g_lock_flags[1][flags]++;
    LeaveCriticalSection(&g_cs);
    return ((PFN_BufLock)g_ib_lock_orig)(self, off, size, data, flags);
}
static HRESULT WINAPI hook_tex_lock(IDirect3DTexture9 *self, UINT lvl, D3DLOCKED_RECT *r, const RECT *rc, DWORD flags) {
    EnterCriticalSection(&g_cs);
    g_lock_flags[2][flags | (rc ? 0x80000000u : 0)]++;
    LeaveCriticalSection(&g_cs);
    return ((PFN_TexLock)g_tex_lock_orig)(self, lvl, r, rc, flags);
}

// ---------------------------------------------------------------------------------
// device hooks
static void note_draw(int kind, D3DPRIMITIVETYPE t, UINT prims) {
    EnterCriticalSection(&g_cs);
    int ti = (t >= 1 && t <= 6) ? (int)t : 0;
    g_draw[kind][ti].calls++;
    g_draw[kind][ti].prims += prims;
    g_draw_mode[g_cur_vs][g_cur_ps]++;
    bool rhw = g_cur_use_decl ? g_cur_decl_rhw : ((g_cur_fvf & 0x400E) == D3DFVF_XYZRHW);
    if (rhw && !g_cur_vs) g_draw_rhw++;
    g_draw_total++;
    g_frame_draws++;
    uint32_t bit = 1u << ((g_cur_vs ? 4 : 0) + (g_cur_ps ? 2 : 0) + ((rhw && !g_cur_vs) ? 1 : 0));
    if (!(g_draw_seen[kind][ti] & bit)) {
        g_draw_seen[kind][ti] |= bit;
        static const char *kn[] = {"DrawPrimitive", "DrawIndexedPrimitive", "DrawPrimitiveUP", "DrawIndexedPrimitiveUP"};
        event_once(std::string(kn[kind]) + " " + prim_name(ti) + (g_cur_vs ? " vs=shader" : " vs=FIXED-FUNCTION") +
                   (g_cur_ps ? " ps=shader" : " ps=FIXED-FUNCTION") + (rhw && !g_cur_vs ? " pre-transformed" : ""));
    }
    LeaveCriticalSection(&g_cs);
}
static HRESULT WINAPI hk_DrawPrimitive(IDirect3DDevice9 *d, D3DPRIMITIVETYPE t, UINT sv, UINT pc) {
    COUNT(DEV_DrawPrimitive);
    note_draw(0, t, pc);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, D3DPRIMITIVETYPE, UINT, UINT), DEV_DrawPrimitive)(d, t, sv, pc);
}
static HRESULT WINAPI hk_DrawIndexedPrimitive(IDirect3DDevice9 *d, D3DPRIMITIVETYPE t, INT bv, UINT mi, UINT nv, UINT si, UINT pc) {
    COUNT(DEV_DrawIndexedPrimitive);
    note_draw(1, t, pc);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, D3DPRIMITIVETYPE, INT, UINT, UINT, UINT, UINT), DEV_DrawIndexedPrimitive)(d, t, bv, mi, nv, si, pc);
}
static HRESULT WINAPI hk_DrawPrimitiveUP(IDirect3DDevice9 *d, D3DPRIMITIVETYPE t, UINT pc, const void *v, UINT st) {
    COUNT(DEV_DrawPrimitiveUP);
    note_draw(2, t, pc);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, D3DPRIMITIVETYPE, UINT, const void *, UINT), DEV_DrawPrimitiveUP)(d, t, pc, v, st);
}
static HRESULT WINAPI hk_DrawIndexedPrimitiveUP(IDirect3DDevice9 *d, D3DPRIMITIVETYPE t, UINT mi, UINT nv, UINT pc, const void *ix,
                                                D3DFORMAT ifmt, const void *v, UINT st) {
    COUNT(DEV_DrawIndexedPrimitiveUP);
    note_draw(3, t, pc);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, D3DPRIMITIVETYPE, UINT, UINT, UINT, const void *, D3DFORMAT, const void *, UINT),
                DEV_DrawIndexedPrimitiveUP)(d, t, mi, nv, pc, ix, ifmt, v, st);
}
static HRESULT WINAPI hk_SetRenderState(IDirect3DDevice9 *d, D3DRENDERSTATETYPE s, DWORD v) {
    COUNT(DEV_SetRenderState);
    EnterCriticalSection(&g_cs);
    if ((DWORD)s < 256) g_rs[s].add(v);
    LeaveCriticalSection(&g_cs);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, D3DRENDERSTATETYPE, DWORD), DEV_SetRenderState)(d, s, v);
}
static HRESULT WINAPI hk_SetTextureStageState(IDirect3DDevice9 *d, DWORD stage, D3DTEXTURESTAGESTATETYPE s, DWORD v) {
    COUNT(DEV_SetTextureStageState);
    EnterCriticalSection(&g_cs);
    if ((DWORD)s < 33) g_tss[s].add(v);
    if (stage < 32 && !(g_stage_seen & (1u << stage))) {
        g_stage_seen |= 1u << stage;
        char b[48];
        snprintf(b, sizeof b, "texture stage %lu used", (unsigned long)stage);
        event_once(b);
    }
    LeaveCriticalSection(&g_cs);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, DWORD, D3DTEXTURESTAGESTATETYPE, DWORD), DEV_SetTextureStageState)(d, stage, s, v);
}
static HRESULT WINAPI hk_SetSamplerState(IDirect3DDevice9 *d, DWORD smp, D3DSAMPLERSTATETYPE s, DWORD v) {
    COUNT(DEV_SetSamplerState);
    EnterCriticalSection(&g_cs);
    if ((DWORD)s < 14) g_samp[s].add(v);
    LeaveCriticalSection(&g_cs);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, DWORD, D3DSAMPLERSTATETYPE, DWORD), DEV_SetSamplerState)(d, smp, s, v);
}
static HRESULT WINAPI hk_SetFVF(IDirect3DDevice9 *d, DWORD fvf) {
    COUNT(DEV_SetFVF);
    EnterCriticalSection(&g_cs);
    g_cur_fvf = fvf;
    g_cur_use_decl = false;
    g_fvf[fvf]++;
    LeaveCriticalSection(&g_cs);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, DWORD), DEV_SetFVF)(d, fvf);
}
static HRESULT WINAPI hk_SetVertexDeclaration(IDirect3DDevice9 *d, IDirect3DVertexDeclaration9 *decl) {
    COUNT(DEV_SetVertexDeclaration);
    EnterCriticalSection(&g_cs);
    g_cur_use_decl = decl != nullptr;
    auto it = g_decl_rhw.find(decl);
    g_cur_decl_rhw = it != g_decl_rhw.end() && it->second;
    LeaveCriticalSection(&g_cs);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, IDirect3DVertexDeclaration9 *), DEV_SetVertexDeclaration)(d, decl);
}
static HRESULT WINAPI hk_CreateVertexDeclaration(IDirect3DDevice9 *d, const D3DVERTEXELEMENT9 *el, IDirect3DVertexDeclaration9 **out) {
    COUNT(DEV_CreateVertexDeclaration);
    HRESULT hr = ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, const D3DVERTEXELEMENT9 *, IDirect3DVertexDeclaration9 **),
                      DEV_CreateVertexDeclaration)(d, el, out);
    if (SUCCEEDED(hr) && el && out && *out) {
        static const char *types[] = {"FLOAT1", "FLOAT2", "FLOAT3", "FLOAT4", "D3DCOLOR", "UBYTE4", "SHORT2", "SHORT4",
                                      "UBYTE4N", "SHORT2N", "SHORT4N", "USHORT2N", "USHORT4N", "UDEC3", "DEC3N",
                                      "FLOAT16_2", "FLOAT16_4", "UNUSED"};
        static const char *usages[] = {"POSITION", "BLENDWEIGHT", "BLENDINDICES", "NORMAL", "PSIZE", "TEXCOORD",
                                       "TANGENT", "BINORMAL", "TESSFACTOR", "POSITIONT", "COLOR", "FOG", "DEPTH", "SAMPLE"};
        std::string s;
        bool rhw = false;
        for (int i = 0; i < 64 && el[i].Stream != 0xFF; i++) {
            char b[96];
            snprintf(b, sizeof b, "%s[s%u+%u %s %s%u]", i ? " " : "", el[i].Stream, el[i].Offset,
                     el[i].Type < 18 ? types[el[i].Type] : "?", el[i].Usage < 14 ? usages[el[i].Usage] : "?", el[i].UsageIndex);
            s += b;
            if (el[i].Usage == D3DDECLUSAGE_POSITIONT) rhw = true;
        }
        EnterCriticalSection(&g_cs);
        g_decl_rhw[*out] = rhw;
        bump(g_decls, s);
        event_once("vertex declaration " + s);
        LeaveCriticalSection(&g_cs);
    }
    return hr;
}
static uint32_t fnv1a(const void *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) h = (h ^ ((const uint8_t *)p)[i]) * 16777619u;
    return h;
}
// Length of D3D9 shader bytecode in DWORDs, up to and including the end token.
static size_t shader_len(const DWORD *f) {
    for (size_t i = 1; i < 65536; i++) {
        DWORD t = f[i];
        if (t == 0x0000FFFF) return i + 1;
        if ((t & 0xFFFF) == 0xFFFE) i += (t >> 16) & 0x7FFF;   // comment block
    }
    return 0;
}
static void note_shader(const DWORD *fn, bool pixel) {
    if (!fn) return;
    DWORD ver = fn[0];
    char model[32];
    snprintf(model, sizeof model, "%s_%lu_%lu", pixel ? "ps" : "vs", (unsigned long)((ver >> 8) & 0xFF),
             (unsigned long)(ver & 0xFF));
    size_t n = shader_len(fn);
    uint32_t h = n ? fnv1a(fn, n * 4) : 0;
    EnterCriticalSection(&g_cs);
    g_shader_count[pixel]++;
    bump(g_shader_models, model);
    event_once(std::string("shader model ") + model);
    if (n && g_shader_hashes.insert(h ^ (pixel ? 0x80000000u : 0)).second) {
        char path[MAX_PATH];
        snprintf(path, sizeof path, "%s\\shaders\\%s_%08x.bin", g_dir.c_str(), model, h);
        FILE *f = fopen(path, "wb");
        if (f) { fwrite(fn, 4, n, f); fclose(f); }
    }
    LeaveCriticalSection(&g_cs);
}
static HRESULT WINAPI hk_CreateVertexShader(IDirect3DDevice9 *d, const DWORD *fn, IDirect3DVertexShader9 **out) {
    COUNT(DEV_CreateVertexShader);
    note_shader(fn, false);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, const DWORD *, IDirect3DVertexShader9 **), DEV_CreateVertexShader)(d, fn, out);
}
static HRESULT WINAPI hk_CreatePixelShader(IDirect3DDevice9 *d, const DWORD *fn, IDirect3DPixelShader9 **out) {
    COUNT(DEV_CreatePixelShader);
    note_shader(fn, true);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, const DWORD *, IDirect3DPixelShader9 **), DEV_CreatePixelShader)(d, fn, out);
}
static HRESULT WINAPI hk_SetVertexShader(IDirect3DDevice9 *d, IDirect3DVertexShader9 *s) {
    COUNT(DEV_SetVertexShader);
    g_cur_vs = s != nullptr;
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, IDirect3DVertexShader9 *), DEV_SetVertexShader)(d, s);
}
static HRESULT WINAPI hk_SetPixelShader(IDirect3DDevice9 *d, IDirect3DPixelShader9 *s) {
    COUNT(DEV_SetPixelShader);
    g_cur_ps = s != nullptr;
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, IDirect3DPixelShader9 *), DEV_SetPixelShader)(d, s);
}
static HRESULT WINAPI hk_CreateTexture(IDirect3DDevice9 *d, UINT w, UINT h, UINT lv, DWORD us, D3DFORMAT fmt, D3DPOOL pool,
                                       IDirect3DTexture9 **out, HANDLE *sh) {
    COUNT(DEV_CreateTexture);
    HRESULT hr = ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, UINT, UINT, UINT, DWORD, D3DFORMAT, D3DPOOL, IDirect3DTexture9 **, HANDLE *),
                      DEV_CreateTexture)(d, w, h, lv, us, fmt, pool, out, sh);
    if (SUCCEEDED(hr) && out && *out) {
        if (!g_tex_hooked) {
            g_tex_hooked = true;
            g_tex_lock_orig = patch_one(*(void ***)*out, 19, (void *)hook_tex_lock);
        }
        std::string k = fmt_name(fmt) + " usage=" + usage_str(us) + " pool=" + pool_name(pool) + (w != h ? " non-square" : "") +
                        ((w & (w - 1)) || (h & (h - 1)) ? " NON-POW2" : "");
        EnterCriticalSection(&g_cs);
        bump(g_textures, k);
        event_once("texture " + k);
        LeaveCriticalSection(&g_cs);
    }
    return hr;
}
static HRESULT WINAPI hk_CreateVertexBuffer(IDirect3DDevice9 *d, UINT len, DWORD us, DWORD fvf, D3DPOOL pool,
                                            IDirect3DVertexBuffer9 **out, HANDLE *sh) {
    COUNT(DEV_CreateVertexBuffer);
    HRESULT hr = ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, UINT, DWORD, DWORD, D3DPOOL, IDirect3DVertexBuffer9 **, HANDLE *),
                      DEV_CreateVertexBuffer)(d, len, us, fvf, pool, out, sh);
    if (SUCCEEDED(hr) && out && *out) {
        if (!g_vb_hooked) {
            g_vb_hooked = true;
            g_vb_lock_orig = patch_one(*(void ***)*out, 11, (void *)hook_vb_lock);
        }
        std::string k = std::string("VertexBuffer usage=") + usage_str(us) + " pool=" + pool_name(pool) + (fvf ? " fvf" : "");
        EnterCriticalSection(&g_cs);
        bump(g_buffers, k);
        event_once(k);
        LeaveCriticalSection(&g_cs);
    }
    return hr;
}
static HRESULT WINAPI hk_CreateIndexBuffer(IDirect3DDevice9 *d, UINT len, DWORD us, D3DFORMAT fmt, D3DPOOL pool,
                                           IDirect3DIndexBuffer9 **out, HANDLE *sh) {
    COUNT(DEV_CreateIndexBuffer);
    HRESULT hr = ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, UINT, DWORD, D3DFORMAT, D3DPOOL, IDirect3DIndexBuffer9 **, HANDLE *),
                      DEV_CreateIndexBuffer)(d, len, us, fmt, pool, out, sh);
    if (SUCCEEDED(hr) && out && *out) {
        if (!g_ib_hooked) {
            g_ib_hooked = true;
            g_ib_lock_orig = patch_one(*(void ***)*out, 11, (void *)hook_ib_lock);
        }
        std::string k = "IndexBuffer " + fmt_name(fmt) + " usage=" + usage_str(us) + " pool=" + pool_name(pool);
        EnterCriticalSection(&g_cs);
        bump(g_buffers, k);
        event_once(k);
        LeaveCriticalSection(&g_cs);
    }
    return hr;
}
static std::string pp_str(const D3DPRESENT_PARAMETERS *pp, DWORD behavior) {
    if (!pp) return "(null)";
    char b[512];
    snprintf(b, sizeof b,
             "%ux%u backbuffer=%s x%u windowed=%d swap=%u interval=0x%lx msaa=%u depth=%s(%s) flags=0x%lx refresh=%u behavior=%s%s%s%s",
             pp->BackBufferWidth, pp->BackBufferHeight, fmt_name(pp->BackBufferFormat).c_str(), pp->BackBufferCount,
             pp->Windowed, (unsigned)pp->SwapEffect, (unsigned long)pp->PresentationInterval, (unsigned)pp->MultiSampleType,
             pp->EnableAutoDepthStencil ? "auto" : "none", fmt_name(pp->AutoDepthStencilFormat).c_str(),
             (unsigned long)pp->Flags, pp->FullScreen_RefreshRateInHz,
             (behavior & D3DCREATE_HARDWARE_VERTEXPROCESSING) ? "HW_VP" : "",
             (behavior & D3DCREATE_SOFTWARE_VERTEXPROCESSING) ? "SW_VP" : "",
             (behavior & D3DCREATE_MIXED_VERTEXPROCESSING) ? "MIXED_VP" : "",
             (behavior & D3DCREATE_MULTITHREADED) ? "|MULTITHREADED" : "");
    return b;
}
static DWORD g_behavior;
static HRESULT WINAPI hk_Reset(IDirect3DDevice9 *d, D3DPRESENT_PARAMETERS *pp) {
    COUNT(DEV_Reset);
    EnterCriticalSection(&g_cs);
    bump(g_present_params, "Reset: " + pp_str(pp, g_behavior));
    event_once("Reset " + pp_str(pp, g_behavior));
    LeaveCriticalSection(&g_cs);
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, D3DPRESENT_PARAMETERS *), DEV_Reset)(d, pp);
}

static void write_summary(bool at_exit = false);
static HRESULT WINAPI hk_Present(IDirect3DDevice9 *d, const RECT *a, const RECT *b, HWND w, const RGNDATA *r) {
    COUNT(DEV_Present);
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    EnterCriticalSection(&g_cs);
    g_frames++;
    g_tl_frames++;
    if (g_frame_draws > g_frame_draws_max) g_frame_draws_max = g_frame_draws;
    g_tl_draws += g_frame_draws;
    g_frame_draws = 0;
    if (g_last_present.QuadPart) {
        uint64_t dt = now.QuadPart - g_last_present.QuadPart;
        g_frame_ticks_total += dt;
        if (dt > g_frame_ticks_max) g_frame_ticks_max = dt;
    }
    g_last_present = now;
    double since_tl = (double)(now.QuadPart - g_last_timeline.QuadPart) / g_qpf.QuadPart;
    if (since_tl >= 5.0) {
        LONG calls = 0;
        for (int i = 0; i < TRACE_DEV_COUNT; i++) calls += g_dev_count[i];
        char line[200];
        snprintf(line, sizeof line, "%8.1fs  frame %-8llu  %6.1f fps  %7.1f draws/frame  %8.0f device calls/frame\r\n",
                 secs_since_start(), (unsigned long long)g_frames, g_tl_frames / since_tl,
                 g_tl_frames ? (double)g_tl_draws / g_tl_frames : 0.0,
                 g_tl_frames ? (double)(calls - g_tl_calls_base) / g_tl_frames : 0.0);
        append_file("timeline.txt", line);
        g_tl_frames = g_tl_draws = 0;
        g_tl_calls_base = calls;
        g_last_timeline = now;
    }
    bool summary = (double)(now.QuadPart - g_last_summary.QuadPart) / g_qpf.QuadPart >= 30.0;
    if (summary) g_last_summary = now;
    LeaveCriticalSection(&g_cs);
    if (summary) write_summary();
    return ORIG(HRESULT(WINAPI *)(IDirect3DDevice9 *, const RECT *, const RECT *, HWND, const RGNDATA *), DEV_Present)(d, a, b, w, r);
}

static void hook_device(IDirect3DDevice9 *dev) {
    if (g_dev_hooked || !dev) return;
    g_dev_hooked = true;
    void *repl[TRACE_DEV_COUNT];
    for (int i = 0; i < TRACE_DEV_COUNT; i++) repl[i] = g_dev_stubs[i];
#define H(m) repl[DEV_##m] = (void *)hk_##m;
    H(DrawPrimitive) H(DrawIndexedPrimitive) H(DrawPrimitiveUP) H(DrawIndexedPrimitiveUP)
    H(SetRenderState) H(SetTextureStageState) H(SetSamplerState) H(SetFVF) H(SetVertexDeclaration)
    H(CreateVertexDeclaration) H(CreateVertexShader) H(CreatePixelShader) H(SetVertexShader) H(SetPixelShader)
    H(CreateTexture) H(CreateVertexBuffer) H(CreateIndexBuffer) H(Reset) H(Present)
#undef H
    patch_vtable(*(void ***)dev, TRACE_DEV_COUNT, g_dev_orig, repl);
}

// ---------------------------------------------------------------------------------
// IDirect3D9 hooks
static HRESULT WINAPI hk_CreateDevice(IDirect3D9 *self, UINT ad, D3DDEVTYPE dt, HWND w, DWORD bf, D3DPRESENT_PARAMETERS *pp,
                                      IDirect3DDevice9 **out) {
    InterlockedIncrement(&g_d3d_count[D3D_CreateDevice]);
    std::string before = pp_str(pp, bf);
    HRESULT hr = ((HRESULT(WINAPI *)(IDirect3D9 *, UINT, D3DDEVTYPE, HWND, DWORD, D3DPRESENT_PARAMETERS *, IDirect3DDevice9 **))
                      g_d3d_orig[D3D_CreateDevice])(self, ad, dt, w, bf, pp, out);
    EnterCriticalSection(&g_cs);
    g_behavior = bf;
    char b[32];
    snprintf(b, sizeof b, " -> hr=0x%08lx", (unsigned long)hr);
    bump(g_present_params, "CreateDevice: " + before + b);
    event_once("CreateDevice " + before + b);
    LeaveCriticalSection(&g_cs);
    if (SUCCEEDED(hr) && out) hook_device(*out);
    return hr;
}
static HRESULT WINAPI hk_CheckDeviceFormat(IDirect3D9 *self, UINT ad, D3DDEVTYPE dt, D3DFORMAT af, DWORD us, D3DRESOURCETYPE rt,
                                           D3DFORMAT cf) {
    InterlockedIncrement(&g_d3d_count[D3D_CheckDeviceFormat]);
    HRESULT hr = ((HRESULT(WINAPI *)(IDirect3D9 *, UINT, D3DDEVTYPE, D3DFORMAT, DWORD, D3DRESOURCETYPE, D3DFORMAT))
                      g_d3d_orig[D3D_CheckDeviceFormat])(self, ad, dt, af, us, rt, cf);
    static const char *rts[] = {"?", "SURFACE", "VOLUME", "TEXTURE", "VOLUMETEXTURE", "CUBETEXTURE", "VERTEXBUFFER", "INDEXBUFFER"};
    EnterCriticalSection(&g_cs);
    bump(g_formats_probed, fmt_name(cf) + " as " + ((DWORD)rt < 8 ? rts[rt] : "?") + " usage=" + usage_str(us) +
                               (SUCCEEDED(hr) ? " -> supported" : " -> NOT supported"));
    LeaveCriticalSection(&g_cs);
    return hr;
}
static void hook_d3d(IDirect3D9 *d3d) {
    if (g_d3d_hooked || !d3d) return;
    g_d3d_hooked = true;
    void *repl[TRACE_D3D_COUNT];
    for (int i = 0; i < TRACE_D3D_COUNT; i++) repl[i] = g_d3d_stubs[i];
    repl[D3D_CreateDevice] = (void *)hk_CreateDevice;
    repl[D3D_CheckDeviceFormat] = (void *)hk_CheckDeviceFormat;
    patch_vtable(*(void ***)d3d, TRACE_D3D_COUNT, g_d3d_orig, repl);
}

// ---------------------------------------------------------------------------------
// summary
static std::string stats_section(const char *title, ValueStats *arr, int n, const char *(*namef)(DWORD), bool texop) {
    std::string s = std::string("\r\n== ") + title + " (state: times set; values seen)\r\n";
    for (int i = 0; i < n; i++) {
        if (!arr[i].sets) continue;
        const char *nm = namef((DWORD)i);
        char b[96];
        snprintf(b, sizeof b, "  %-26s %10llu  ", nm ? nm : ("#" + std::to_string(i)).c_str(), (unsigned long long)arr[i].sets);
        s += b;
        for (auto &v : arr[i].values) {
            char c[64];
            const char *on = texop ? texop_name(v.first) : nullptr;
            if (on) snprintf(c, sizeof c, "%s(%llu) ", on, (unsigned long long)v.second);
            else snprintf(c, sizeof c, "0x%lx(%llu) ", (unsigned long)v.first, (unsigned long long)v.second);
            s += c;
        }
        if (arr[i].more) s += "...";
        s += "\r\n";
    }
    return s;
}
static std::string map_section(const char *title, const std::map<std::string, uint64_t> &m) {
    std::vector<std::pair<uint64_t, std::string>> v;
    for (auto &e : m) v.push_back({e.second, e.first});
    std::sort(v.rbegin(), v.rend());
    std::string s = std::string("\r\n== ") + title + "\r\n";
    if (v.empty()) s += "  (none)\r\n";
    for (auto &e : v) {
        char b[32];
        snprintf(b, sizeof b, "  %10llu  ", (unsigned long long)e.first);
        s += b + e.second + "\r\n";
    }
    return s;
}
static const char *tss_namef(DWORD s) { return tss_name(s); }
static const char *samp_namef(DWORD s) { return samp_name(s); }
static const char *rs_namef(DWORD s) { return rs_name(s); }

// at_exit: never block — a thread killed while holding g_cs would deadlock the exit.
static void write_summary(bool at_exit) {
    if (at_exit) {
        if (!TryEnterCriticalSection(&g_cs)) return;
    } else {
        EnterCriticalSection(&g_cs);
    }
    std::string s;
    char b[512];
    double t = secs_since_start();
    double avg_ms = g_frames > 1 ? 1000.0 * g_frame_ticks_total / g_qpf.QuadPart / (g_frames - 1) : 0;
    snprintf(b, sizeof b,
             "osxEQEmu d3d9trace — summary after %.0f s\r\nframes %llu  (avg %.1f fps, avg frame %.1f ms, worst %.1f ms)\r\n"
             "draws %llu  (avg %.1f/frame, max %llu/frame)\r\n",
             t, (unsigned long long)g_frames, avg_ms > 0 ? 1000.0 / avg_ms : 0.0, avg_ms,
             1000.0 * g_frame_ticks_max / g_qpf.QuadPart, (unsigned long long)g_draw_total,
             g_frames ? (double)g_draw_total / g_frames : 0.0, (unsigned long long)g_frame_draws_max);
    s += b;

    s += map_section("Device creation / Reset parameters", g_present_params);

    // ---- work list for a Direct3D 9 -> Metal front end
    s += "\r\n== WORK LIST for a Direct3D 9 -> Metal translator (what this game needs)\r\n";
    uint64_t ffvs = g_draw_mode[0][0] + g_draw_mode[0][1], ffps = g_draw_mode[0][0] + g_draw_mode[1][0];
    auto pct = [](uint64_t a, uint64_t tot) { return tot ? 100.0 * a / tot : 0.0; };
    snprintf(b, sizeof b, "  [%s] fixed-function VERTEX pipeline: %llu draws (%.0f%%)\r\n", ffvs ? "NEEDED" : "not used",
             (unsigned long long)ffvs, pct(ffvs, g_draw_total));
    s += b;
    snprintf(b, sizeof b, "  [%s] fixed-function PIXEL pipeline (texture stage combiners): %llu draws (%.0f%%)\r\n",
             ffps ? "NEEDED" : "not used", (unsigned long long)ffps, pct(ffps, g_draw_total));
    s += b;
    snprintf(b, sizeof b, "  [%s] pre-transformed vertices (XYZRHW / POSITIONT): %llu draws\r\n", g_draw_rhw ? "NEEDED" : "not used",
             (unsigned long long)g_draw_rhw);
    s += b;
    snprintf(b, sizeof b, "  [%s] vertex shaders: %llu created; pixel shaders: %llu created (models below)\r\n",
             (g_shader_count[0] || g_shader_count[1]) ? "NEEDED" : "not used", (unsigned long long)g_shader_count[0],
             (unsigned long long)g_shader_count[1]);
    s += b;
    uint64_t up = 0;
    for (int ti = 0; ti < 7; ti++) up += g_draw[2][ti].calls + g_draw[3][ti].calls;
    snprintf(b, sizeof b, "  [%s] user-pointer draws (DrawPrimitiveUP / DrawIndexedPrimitiveUP): %llu\r\n", up ? "NEEDED" : "not used",
             (unsigned long long)up);
    s += b;
    bool fog = g_rs[D3DRS_FOGENABLE].values.count(1);
    snprintf(b, sizeof b, "  [%s] fog (FOGTABLEMODE/FOGVERTEXMODE values below)\r\n", fog ? "NEEDED" : "not used");
    s += b;
    bool at = g_rs[D3DRS_ALPHATESTENABLE].values.count(1), st = g_rs[D3DRS_STENCILENABLE].values.count(1),
         cp = g_rs[D3DRS_CLIPPLANEENABLE].sets && (g_rs[D3DRS_CLIPPLANEENABLE].values.size() > 1 || !g_rs[D3DRS_CLIPPLANEENABLE].values.count(0)),
         ps = g_rs[D3DRS_POINTSPRITEENABLE].values.count(1), lit = g_rs[D3DRS_LIGHTING].values.count(1);
    snprintf(b, sizeof b, "  [%s] alpha test   [%s] stencil   [%s] user clip planes   [%s] point sprites   [%s] FF lighting\r\n",
             at ? "NEEDED" : "-", st ? "NEEDED" : "-", cp ? "NEEDED" : "-", ps ? "NEEDED" : "-", lit ? "NEEDED" : "-");
    s += b;
    s += "  texture formats, lock patterns and states: see the sections below (BC/DXT formats map to Metal's BC formats\r\n"
         "  on Apple GPUs; 24-bit R8G8B8, palettes (P8) and L8/A8L8 need conversion or swizzles).\r\n";

    // draws
    s += "\r\n== Draw calls (calls / primitives)\r\n";
    static const char *kn[] = {"DrawPrimitive", "DrawIndexedPrimitive", "DrawPrimitiveUP", "DrawIndexedPrimitiveUP"};
    for (int k = 0; k < 4; k++)
        for (int ti = 0; ti < 7; ti++)
            if (g_draw[k][ti].calls) {
                snprintf(b, sizeof b, "  %-24s %-14s %10llu calls %12llu prims\r\n", kn[k], prim_name(ti),
                         (unsigned long long)g_draw[k][ti].calls, (unsigned long long)g_draw[k][ti].prims);
                s += b;
            }
    snprintf(b, sizeof b, "  pipeline at draw time: FF-vs+FF-ps %llu | FF-vs+shader-ps %llu | shader-vs+FF-ps %llu | shaders %llu\r\n",
             (unsigned long long)g_draw_mode[0][0], (unsigned long long)g_draw_mode[0][1], (unsigned long long)g_draw_mode[1][0],
             (unsigned long long)g_draw_mode[1][1]);
    s += b;

    s += map_section("Shader models (created)", g_shader_models);
    {
        std::map<std::string, uint64_t> m;
        for (auto &e : g_fvf) m[fvf_str(e.first)] += e.second;
        s += map_section("Vertex formats (SetFVF)", m);
    }
    s += map_section("Vertex declarations (created)", g_decls);
    s += map_section("Textures created (format, usage, pool)", g_textures);
    s += map_section("Buffers created", g_buffers);
    {
        static const char *kinds[] = {"VertexBuffer Lock ", "IndexBuffer Lock ", "Texture LockRect "};
        std::map<std::string, uint64_t> m;
        for (int k = 0; k < 3; k++)
            for (auto &e : g_lock_flags[k])
                m[kinds[k] + lock_str(e.first & 0x7FFFFFFF) + ((e.first & 0x80000000u) ? " (sub-rect)" : "")] += e.second;
        s += map_section("Lock flags", m);
    }
    s += stats_section("Render states", g_rs, 256, rs_namef, false);
    s += stats_section("Texture stage states (all stages; COLOROP/ALPHAOP shown by name)", g_tss, 33, tss_namef, true);
    s += stats_section("Sampler states (all samplers)", g_samp, 14, samp_namef, false);
    s += map_section("Formats probed (CheckDeviceFormat)", g_formats_probed);

    // all methods
    s += "\r\n== IDirect3DDevice9 methods called (total, per frame)\r\n";
    std::vector<std::pair<LONG, int>> m;
    for (int i = 0; i < TRACE_DEV_COUNT; i++)
        if (g_dev_count[i]) m.push_back({g_dev_count[i], i});
    std::sort(m.rbegin(), m.rend());
    for (auto &e : m) {
        snprintf(b, sizeof b, "  %-30s %12ld  %10.1f/frame\r\n", g_dev_names[e.second], (long)e.first,
                 g_frames ? (double)e.first / g_frames : 0.0);
        s += b;
    }
    s += "\r\n== IDirect3D9 methods called\r\n";
    for (int i = 0; i < TRACE_D3D_COUNT; i++)
        if (g_d3d_count[i]) {
            snprintf(b, sizeof b, "  %-30s %12ld\r\n", g_d3d_names[i], (long)g_d3d_count[i]);
            s += b;
        }
    s += "\r\n== Never called (no need to implement for this game, as far as this session went)\r\n  ";
    int col = 0;
    for (int i = 0; i < TRACE_DEV_COUNT; i++)
        if (!g_dev_count[i]) {
            s += g_dev_names[i];
            s += (++col % 4) ? ", " : ",\r\n  ";
        }
    s += "\r\n";
    LeaveCriticalSection(&g_cs);

    std::string p = g_dir + "\\summary.txt";
    FILE *f = fopen(p.c_str(), "wb");
    if (f) {
        fwrite(s.data(), 1, s.size(), f);
        fclose(f);
    }
}

// ---------------------------------------------------------------------------------
// exports
extern "C" IDirect3D9 *WINAPI trace_Direct3DCreate9(UINT sdk) {
    typedef IDirect3D9 *(WINAPI * PFN)(UINT);
    PFN real = g_real ? (PFN)GetProcAddress(g_real, "Direct3DCreate9") : nullptr;
    IDirect3D9 *d = real ? real(sdk) : nullptr;
    EnterCriticalSection(&g_cs);
    char b[64];
    snprintf(b, sizeof b, "Direct3DCreate9(sdk %u) -> %s", sdk, d ? "ok" : "FAILED");
    event_once(b);
    LeaveCriticalSection(&g_cs);
    hook_d3d(d);
    return d;
}
extern "C" HRESULT WINAPI trace_Direct3DCreate9Ex(UINT sdk, IDirect3D9Ex **out) {
    typedef HRESULT(WINAPI * PFN)(UINT, IDirect3D9Ex **);
    PFN real = g_real ? (PFN)GetProcAddress(g_real, "Direct3DCreate9Ex") : nullptr;
    HRESULT hr = real ? real(sdk, out) : E_NOTIMPL;
    EnterCriticalSection(&g_cs);
    event_once("Direct3DCreate9Ex used");
    LeaveCriticalSection(&g_cs);
    if (SUCCEEDED(hr) && out) hook_d3d((IDirect3D9 *)*out);   // IDirect3D9Ex starts with the IDirect3D9 vtable
    return hr;
}
extern "C" int WINAPI fwd_missing() { return 0; }

static void init() {
    InitializeCriticalSection(&g_cs);
    QueryPerformanceFrequency(&g_qpf);
    QueryPerformanceCounter(&g_t0);
    g_last_timeline = g_last_summary = g_t0;

    char dir[MAX_PATH];
    DWORD n = GetEnvironmentVariableA("OSXEQEMU_TRACE_DIR", dir, sizeof dir);
    g_dir = (n && n < sizeof dir) ? std::string(dir) : std::string(".\\d3d9-trace");
    CreateDirectoryA(g_dir.c_str(), nullptr);
    CreateDirectoryA((g_dir + "\\shaders").c_str(), nullptr);

    // The real d3d9: the system one, never ourselves.
    char sys[MAX_PATH];
    GetSystemDirectoryA(sys, sizeof sys);
    std::string real = std::string(sys) + "\\d3d9.dll";
    g_real = LoadLibraryA(real.c_str());
    HMODULE self = nullptr;
    GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       (LPCSTR)&init, &self);
    if (g_real == self) g_real = nullptr;
    static const char *const names[] = {
#define X(m) #m,
        TRACE_FORWARDS(X)
#undef X
    };
    for (int i = 0; i < TRACE_FWD_COUNT; i++) {
        void *p = g_real ? (void *)GetProcAddress(g_real, names[i]) : nullptr;
        g_fwd_ptr[i] = p ? p : (void *)fwd_missing;
    }
    char b[MAX_PATH + 64];
    snprintf(b, sizeof b, "d3d9trace loaded; real d3d9: %s (%s)", real.c_str(), g_real ? "ok" : "NOT FOUND");
    event_once(b);
}

BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) init();
    else if (reason == DLL_PROCESS_DETACH && g_dir.size()) write_summary(true);
    return TRUE;
}
