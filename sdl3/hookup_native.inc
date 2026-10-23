// ===================== sdl3bridge: Steam Native Hook-up =====================
// The SDL3 bridge app passes a USB controller through raw: its real USB identity (vendor/product id,
// name, serial, interface, HID report descriptor) and every HID report, both ways. Here each such
// controller becomes a real-looking /dev/hidraw24..27 node, so Steam's own drivers recognise it exactly
// as on a PC (DualSense / Edge, DualShock 4, Switch / Switch 2, Xbox, Flydigi, 8BitDo, Steam Controller,
// ...) and use all of its features. DroidDeck's app side (HookupBridge.kt) fills the shared file named by
// FAKE_HOOKUP_SHM; this side serves Steam's open/read/write/ioctl calls and announces hot-plug to udev.
//
// Game rumble: games rumble Steam's virtual pad; DroidDeck normally handles that itself. While a hooked-up
// controller is present (ff_to_steam), the effect is handed to Steam instead -- through the virtual pad's
// uinput force-feedback protocol -- so Steam rumbles the real controller with its own driver, like on a PC.
static constexpr uint32_t HOOKUP_MAGIC = 0x4b4f4f48;  // "HOOK"
static constexpr int HOOKUP_SLOTS = 4;
static constexpr int HOOKUP_IN_FIFO = 256;
static constexpr int HOOKUP_OUT_FIFO = 64;
static constexpr int HOOKUP_REPORT_MAX = 128;
static constexpr int HOOKUP_DESC_MAX = 4096;
static constexpr int HOOKUP_FF_NODES = UINPUT_EVENT_LIMIT - UINPUT_EVENT_BASE;
static constexpr unsigned HOOKUP_MINOR_BASE = 24;
static constexpr size_t HOOKUP_HEADER_SIZE = 4096;
static constexpr size_t HOOKUP_SLOT_SIZE = 53248;
static constexpr size_t HOOKUP_SIZE = HOOKUP_HEADER_SIZE + HOOKUP_SLOTS * HOOKUP_SLOT_SIZE;
static constexpr int HOOKUP_FEATURE_TIMEOUT_MS = 1000;
static constexpr int HOOKUP_OUTPUT_WAIT_MS = 50;   // feature writes (settings): wait this long for room
static constexpr int HOOKUP_REPORT_WAIT_MS = 4;    // output reports (rumble, lights): newer ones follow, so drop
static constexpr int HOOKUP_FUTEX_WAIT = 0;  // FUTEX_WAIT, shared: the writer is the SDL3 bridge, another process

struct HookupReport {
  uint64_t seq;
  uint32_t length;
  uint32_t kind;  // output fifo: 0 output report, 1 feature write
  uint8_t data[HOOKUP_REPORT_MAX];
};
struct HookupSlot {
  uint32_t present;
  uint32_t generation;
  uint16_t vendor, product, version, bus;
  int32_t iface;
  uint32_t desc_len;
  char name[128];
  char serial[64];
  char manufacturer[64];
  char product_name[64];
  uint64_t in_write;
  uint64_t out_write;
  uint64_t out_read;
  uint64_t get_request;
  uint64_t get_reply;
  uint32_t get_report_id;  // low byte: report id; bit 8: input report (HIDIOCGINPUT) instead of feature
  int32_t get_length;
  uint8_t get[HOOKUP_REPORT_MAX];
  uint64_t direct_ms;  // SDL3 bridge heartbeat (CLOCK_MONOTONIC ms) while it writes this slot itself (fast path)
  uint8_t reserved[1024 - 528];
  uint8_t desc[HOOKUP_DESC_MAX];
  HookupReport in[HOOKUP_IN_FIFO];
  HookupReport out[HOOKUP_OUT_FIFO];
};
struct HookupFF {
  uint64_t seq;
  int32_t strong;
  int32_t weak;
  uint32_t length;
  uint32_t play;
};
struct HookupHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t ff_to_steam;
  uint32_t reserved[13];
  HookupFF ff[HOOKUP_FF_NODES];
};
static_assert(sizeof(HookupReport) == 144, "HookupReport layout");
static_assert(offsetof(HookupSlot, name) == 24, "hookup name offset");
static_assert(offsetof(HookupSlot, serial) == 152, "hookup serial offset");
static_assert(offsetof(HookupSlot, manufacturer) == 216, "hookup manufacturer offset");
static_assert(offsetof(HookupSlot, product_name) == 280, "hookup product offset");
static_assert(offsetof(HookupSlot, in_write) == 344, "hookup in_write offset");
static_assert(offsetof(HookupSlot, get_report_id) == 384, "hookup get_report_id offset");
static_assert(offsetof(HookupSlot, get) == 392, "hookup get offset");
static_assert(offsetof(HookupSlot, direct_ms) == 520, "hookup direct_ms offset");
static_assert(offsetof(HookupSlot, desc) == 1024, "hookup desc offset");
static_assert(offsetof(HookupSlot, in) == 5120, "hookup in offset");
static_assert(offsetof(HookupSlot, out) == 41984, "hookup out offset");
static_assert(sizeof(HookupSlot) <= HOOKUP_SLOT_SIZE, "hookup slot size");
static_assert(offsetof(HookupHeader, ff) == 64, "hookup ff offset");
static_assert(sizeof(HookupFF) == 24, "hookup ff entry");
static_assert(sizeof(HookupHeader) <= HOOKUP_HEADER_SIZE, "hookup header size");

__attribute__((visibility("hidden"))) static uint8_t *hookup_shm() {
  static uint8_t *mapped = nullptr;
  static std::once_flag once;
  std::call_once(once, [] {
    const char *path = getenv("FAKE_HOOKUP_SHM");
    if (!path || !*path) return;
    static auto my_open = reinterpret_cast<int (*)(const char *, int, ...)>(dlsym(RTLD_NEXT, "open"));
    int fd = my_open(path, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
      Logger::log("hookup: %s not openable (%s)\n", path, strerror(errno));
      return;
    }
    struct stat st;
    void *mapping = MAP_FAILED;
    if (fstat(fd, &st) == 0 && static_cast<size_t>(st.st_size) >= HOOKUP_SIZE)
      mapping = mmap(nullptr, HOOKUP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    syscall(SYS_close, fd);
    if (mapping == MAP_FAILED || static_cast<HookupHeader *>(mapping)->magic != HOOKUP_MAGIC) {
      Logger::log("hookup: %s %s\n", path, mapping == MAP_FAILED ? "could not be mapped" : "has no valid header");
      if (mapping != MAP_FAILED) munmap(mapping, HOOKUP_SIZE);
      return;
    }
    mapped = static_cast<uint8_t *>(mapping);
  });
  return mapped;
}

__attribute__((visibility("hidden"))) static HookupHeader *hookup_header() {
  return reinterpret_cast<HookupHeader *>(hookup_shm());
}

__attribute__((visibility("hidden"))) static HookupSlot *hookup_slot(int i) {
  uint8_t *base = hookup_shm();
  if (!base || i < 0 || i >= HOOKUP_SLOTS) return nullptr;
  return reinterpret_cast<HookupSlot *>(base + HOOKUP_HEADER_SIZE + static_cast<size_t>(i) * HOOKUP_SLOT_SIZE);
}

__attribute__((visibility("hidden"))) static bool hookup_present(int i) {
  HookupSlot *s = hookup_slot(i);
  return s && __atomic_load_n(&s->present, __ATOMIC_ACQUIRE) != 0;
}

/** /dev/hidraw24..27 -> slot 0..3 when that slot holds a controller, else -1. */
__attribute__((visibility("hidden"))) static int hookup_path_slot(const char *pathname) {
  if (!pathname || !fake_deck_enabled() || strncmp(pathname, "/dev/hidraw2", 12)) return -1;
  for (int i = 0; i < HOOKUP_SLOTS; i++) {
    char path[32];
    snprintf(path, sizeof(path), "/dev/hidraw%u", HOOKUP_MINOR_BASE + i);
    if (!strcmp(pathname, path)) return hookup_present(i) ? i : -1;
  }
  return -1;
}

/** Must match HookupBridge.kt's sysfs layout. */
__attribute__((visibility("hidden"))) static void hookup_devpath(int i, const HookupSlot &s, char *out, size_t size) {
  int iface = s.iface < 0 ? 0 : s.iface;
  snprintf(out, size, "/devices/droiddeck/usb%d/%d-1:1.%d/0003:%04X:%04X.%04X/hidraw/hidraw%u", 10 + i, 10 + i, iface,
           s.vendor, s.product, 0x10 + i, HOOKUP_MINOR_BASE + i);
}

// ---- latency meter (logged to pad.log every 10 s while it has samples) ----
// Where a button press of a hooked-up controller spends its time, in three steps:
//   1. waiting in Steam's queue: from the report being handed to Steam until Steam reads it,
//   2. Steam's own processing: from Steam reading the press until Steam writes the mapped button on its virtual pad,
//   3. the game: from Steam's virtual pad until the game reads it.
// Mouse / keyboard output from Steam does not go through the virtual pad, so it is in step 1 only.
struct HookupLatency {
  std::mutex lock;
  uint32_t n = 0, missed = 0;
  uint64_t sum_us = 0, max_us = 0, since_us = 0;
  void add(const char *what, uint64_t us, uint64_t now_us, bool hit = true) {
    std::lock_guard<std::mutex> guard(lock);
    if (!since_us) since_us = now_us;
    if (hit) {
      n++;
      sum_us += us;
      if (us > max_us) max_us = us;
    } else {
      missed++;
    }
    if (now_us - since_us < 10000000ULL) return;
    if (n)
      Logger::log("latency: %s: %u presses, avg %.1f ms, max %.1f ms%s\n", what, n, sum_us / 1000.0 / n, max_us / 1000.0,
                  missed ? " (plus presses that never reached the pad: mapped to mouse / keyboard or nothing)" : "");
    n = missed = 0;
    sum_us = max_us = 0;
    since_us = now_us;
  }
};

static std::atomic<uint64_t> g_hookup_press_us{0};   // Steam process: a press Steam has read, not yet on its pad

/**
 * Steam's controller work runs at a higher priority, like Android's own input threads (nice -8): the threads that
 * read controllers (hooked-up ones and DroidDeck's own pads -- every controller), the one that writes Steam's
 * virtual pad, and ours that hand reports over. On a phone the game and the emulation keep the CPU busy, and
 * Steam's controller loop otherwise waits its turn behind them -- that is when it reads late. Once per thread; if
 * Android doesn't allow it, nothing changes (logged once).
 */
__attribute__((visibility("hidden"))) static void hookup_boost_this_thread(const char *what) {
  static thread_local bool done;
  if (done) return;
  done = true;
  if (!process_is_steam_client()) return;
  pid_t tid = static_cast<pid_t>(syscall(SYS_gettid));
  errno = 0;
  int was = getpriority(PRIO_PROCESS, static_cast<id_t>(tid));
  if (errno == 0 && was <= -8) return;
  if (setpriority(PRIO_PROCESS, static_cast<id_t>(tid), -8) == 0) {
    Logger::log("thread %d (%s) now runs at higher priority (nice %d -> -8)\n", tid, what, was);
  } else {
    static std::atomic<bool> told{false};
    if (!told.exchange(true))
      Logger::log("could not raise the priority of thread %d (%s): %s\n", tid, what, strerror(errno));
  }
}
static std::atomic<int> g_hookup_samples{0};

/** Steam process, as Steam writes its virtual pad: the end of step 2. */
__attribute__((visibility("hidden"))) static void hookup_meter_virtual_pad(const std::vector<struct input_event> &events) {
  hookup_boost_this_thread("writes Steam's virtual controller");
  uint64_t press = g_hookup_press_us.load(std::memory_order_acquire);
  if (!press) return;
  static HookupLatency stat;
  uint64_t now = monotonic_us();
  if (now - press > 250000ULL) {  // no gamepad button followed: mapped to mouse / keyboard, or nothing
    if (g_hookup_press_us.compare_exchange_strong(press, 0)) stat.add("button press -> Steam's virtual pad", 0, now, false);
    return;
  }
  for (const struct input_event &ev : events) {
    if (ev.type != EV_KEY || ev.value != 1) continue;
    if (!g_hookup_press_us.compare_exchange_strong(press, 0)) return;
    stat.add("Steam read a button press -> on Steam's virtual pad (Steam's own processing)", now - press, now);
    int sample = g_hookup_samples.fetch_add(1, std::memory_order_relaxed);
    if (sample < 12) Logger::log("latency: press %d: on Steam's virtual pad %.1f ms after Steam read it\n", sample + 1, (now - press) / 1000.0);
    return;
  }
}

/** Game process, as it reads Steam's virtual pad: step 3 (stamped when Steam wrote it). */
__attribute__((visibility("hidden"))) static void hookup_meter_game_read(const struct input_event *events, size_t count) {
  if (process_is_steam_client()) return;
  for (size_t i = 0; i < count; i++) {
    if (events[i].type != EV_KEY || events[i].value != 1) continue;
    struct timeval now = {};
    gettimeofday(&now, nullptr);
    int64_t us = (static_cast<int64_t>(now.tv_sec) - events[i].time.tv_sec) * 1000000LL + (now.tv_usec - events[i].time.tv_usec);
    if (us < 0 || us > 1000000LL) continue;
    static HookupLatency stat;
    stat.add("Steam's virtual pad -> game read", static_cast<uint64_t>(us), monotonic_us());
  }
}

/** Steam's output reports / feature writes to a hooked-up controller, logged every 10 s when Steam had to wait. */
struct HookupOutputStat {
  uint32_t reports = 0, features = 0, dropped = 0;
  uint64_t waited_us = 0, since_us = 0;
};

/**
 * Buttons and hat switches the controller's own HID report descriptor declares for input report `id` (0 = the
 * controller uses no report IDs), as a bit mask over the report bytes (byte 0 = the report ID when IDs are used).
 * Controllers with a standard descriptor get their buttons protected exactly; vendor-defined reports (Sony's extra
 * area, Switch, Steam Controller, Xbox) declare none, and rely on what is learned from the reports.
 */
__attribute__((visibility("hidden"))) static void hookup_descriptor_buttons(const HookupSlot &s, uint8_t id, uint8_t *mask,
                                                                            uint32_t length) {
  const uint8_t *d = s.desc;
  uint32_t n = std::min<uint32_t>(s.desc_len, HOOKUP_DESC_MAX);
  struct Globals { uint32_t page = 0, size = 0, count = 0, id = 0; } g, stack[4];
  int depth = 0;
  uint32_t usages[64];
  int nusages = 0;
  uint32_t umin = 0, umax = 0;
  bool range = false, ids = false;
  uint32_t bitpos[256] = {};
  for (uint32_t pos = 0; pos < n;) {
    uint8_t prefix = d[pos++];
    if (prefix == 0xfe) {  // long item
      if (pos + 1 >= n) break;
      pos += 2 + d[pos];
      continue;
    }
    uint32_t size = prefix & 3;
    if (size == 3) size = 4;
    if (pos + size > n) break;
    uint32_t v = 0;
    for (uint32_t k = 0; k < size; k++) v |= static_cast<uint32_t>(d[pos + k]) << (8 * k);
    pos += size;
    uint32_t type = (prefix >> 2) & 3, tag = prefix >> 4;
    if (type == 1) {  // global
      if (tag == 0) g.page = v;
      else if (tag == 7) g.size = v;
      else if (tag == 8) { g.id = v & 0xff; ids = true; }
      else if (tag == 9) g.count = v;
      else if (tag == 10 && depth < 4) stack[depth++] = g;
      else if (tag == 11 && depth > 0) g = stack[--depth];
    } else if (type == 2) {  // local
      if (tag == 0 && nusages < 64) usages[nusages++] = size == 4 ? v : (g.page << 16) | v;
      else if (tag == 1) { umin = size == 4 ? v : (g.page << 16) | v; range = true; }
      else if (tag == 2) umax = size == 4 ? v : (g.page << 16) | v;
    } else if (type == 0) {  // main
      if (tag == 8) {  // Input
        uint32_t start = bitpos[g.id];
        uint32_t bits = g.size * g.count;
        bitpos[g.id] += bits;
        if (!(v & 1) && g.id == id && g.size && g.size <= 32) {
          for (uint32_t j = 0; j < g.count; j++) {
            uint32_t usage = j < static_cast<uint32_t>(nusages) ? usages[j]
                           : range ? std::min(umin + j, umax ? umax : umin + j)
                           : nusages ? usages[nusages - 1] : (g.page << 16);
            uint32_t page = usage >> 16, u = usage & 0xffff;
            if (page != 0x09 && !(page == 0x01 && u == 0x39)) continue;
            for (uint32_t b = start + j * g.size; b < start + (j + 1) * g.size; b++) {
              uint32_t byte = (ids ? 1 : 0) + b / 8;
              if (byte < length) mask[byte] |= 1u << (b % 8);
            }
          }
        }
      }
      nusages = 0;
      range = false;
      umin = umax = 0;
    }
  }
  (void)ids;
}

/**
 * Which bits of a controller's reports are "moving", learned from the reports themselves for ANY controller (no
 * report layout needed): bytes that change in more than a quarter of the last 256 reports of that kind (sticks in
 * use, gyro, accelerometer, touch position, noise) and single bits that do; and counters / timestamps (a byte that
 * goes up in nearly every report, and the bytes above it that only change when it wraps around). A button is never
 * pressed that fast. Buttons the HID descriptor declares are never "moving". Until the first 256 reports are seen
 * (and for kinds that don't stream) nothing counts as moving.
 */
struct HookupReportKind {
  uint32_t length = 0;
  uint8_t id = 0;              // first byte (the report ID on controllers that use them)
  bool learned = false;
  uint32_t count = 0;
  uint8_t prev[HOOKUP_REPORT_MAX] = {};
  bool has_prev = false;
  uint16_t changes[HOOKUP_REPORT_MAX * 8] = {};
  uint16_t byte_changes[HOOKUP_REPORT_MAX] = {};
  uint16_t ups[HOOKUP_REPORT_MAX] = {};        // byte went up by 1..127 (mod 256)
  uint16_t carried[HOOKUP_REPORT_MAX] = {};    // byte changed while the byte below it wrapped around
  uint16_t uncarried[HOOKUP_REPORT_MAX] = {};  // byte changed while the byte below it did not wrap
  uint8_t moving[HOOKUP_REPORT_MAX] = {};      // 1 bits = moving (or part of a counter)
  bool analog[HOOKUP_REPORT_MAX] = {};         // the whole byte is moving, and it is not a counter
  uint8_t buttons[HOOKUP_REPORT_MAX] = {};     // declared buttons / hat switches (HID descriptor)
  uint8_t given[HOOKUP_REPORT_MAX] = {};       // the last report of this kind Steam got
  bool has_given = false;
  uint64_t window_us = 0;
  void learn(const uint8_t *d, uint64_t now_us) {
    if (!window_us) window_us = now_us;
    if (has_prev) {
      for (uint32_t i = 0; i < length; i++) {
        uint8_t x = d[i] ^ prev[i];
        if (!x) continue;
        byte_changes[i]++;
        for (uint32_t b = x; b; b &= b - 1) changes[i * 8 + __builtin_ctz(b)]++;
        if (static_cast<int8_t>(d[i] - prev[i]) > 0) ups[i]++;
        if (i > 0) {
          if (d[i - 1] < prev[i - 1]) carried[i]++; else uncarried[i]++;
        }
      }
    }
    memcpy(prev, d, length);
    has_prev = true;
    if (++count < 256) return;
    bool counter[HOOKUP_REPORT_MAX] = {};
    for (uint32_t i = 0; i < length; i++) {
      if (ups[i] >= 200) counter[i] = true;                                   // goes up in ~80 % of reports
      else if (i > 0 && counter[i - 1] && carried[i] >= 2 && !uncarried[i]) counter[i] = true;  // its upper part
      analog[i] = !counter[i] && byte_changes[i] > 64 && !buttons[i];
      uint8_t m = counter[i] || byte_changes[i] > 64 ? 0xff : 0;
      for (int b = 0; b < 8; b++)
        if (changes[i * 8 + b] > 64) m |= 1u << b;
      moving[i] = m & ~buttons[i];
    }
    memset(changes, 0, sizeof(changes));
    memset(byte_changes, 0, sizeof(byte_changes));
    memset(ups, 0, sizeof(ups));
    memset(carried, 0, sizeof(carried));
    memset(uncarried, 0, sizeof(uncarried));
    count = 0;
    // Only a kind that streams (256 reports within 5 s) is ever replaced: rarer kinds -- replies to Steam's
    // commands, status reports -- always reach Steam one by one.
    learned = now_us - window_us < 5000000ULL;
    window_us = now_us;
  }
  /**
   * Would replacing `older` by `newer` lose a change Steam has not seen -- a button-like bit that changed (compared
   * with `base`, what Steam has or will get) and changed back? That is a short press-and-release (or the reverse)
   * that must reach Steam. Not counted: moving bits (their next value carries them), and the carry of an analog
   * value crossing a boundary: a bit that changed together with lower bits of its byte, or a byte that moved by
   * 1..3 right above an analog byte (the upper half of a 16-bit value). A declared button always counts.
   */
  bool loses_change(const uint8_t *older, const uint8_t *newer, const uint8_t *base) const {
    for (uint32_t i = 0; i < length; i++) {
      uint8_t changed = older[i] ^ base[i];
      uint8_t reverted = changed & ~(newer[i] ^ base[i]) & ~moving[i];
      for (uint32_t r = reverted; r; r &= r - 1) {
        int b = __builtin_ctz(r);
        if (buttons[i] & (1u << b)) return true;
        if (changed & ((1u << b) - 1)) continue;
        int delta = static_cast<int8_t>(older[i] - base[i]);
        if (i > 0 && analog[i - 1] && delta >= -3 && delta <= 3) continue;
        return true;
      }
    }
    return false;
  }
  /**
   * For the latency meter, any controller: a button press since `ref` -- a declared button (HID descriptor) that
   * turned on, or, for controllers that declare none, a learned non-moving bit that turned on.
   */
  bool press(const uint8_t *d, const uint8_t *ref) const {
    bool declared = false;
    for (uint32_t i = 0; i < length; i++) {
      if (!buttons[i]) continue;
      declared = true;
      if (d[i] & ~ref[i] & buttons[i]) return true;
    }
    if (declared || !learned) return false;
    for (uint32_t i = 0; i < length; i++)
      if (d[i] & ~ref[i] & ~moving[i]) return true;
    return false;
  }
};

/**
 * Controller reports -> Steam's /dev/hidraw node, for every controller: a mailbox read at the moment Steam reads.
 * The report thread keeps the reports Steam has not read yet; Steam's read() of the node is answered from here
 * (hookup_read_steam), and the node's socket only carries a 1-byte "something to read" token, so poll() works
 * as on a real node. Latest wins: a newer report replaces the waiting one, so whenever Steam reads, it gets the
 * newest state -- even when it reads late. A report is only kept (and reaches Steam in order) when replacing it
 * would lose a change: a button-like bit that changed and changed back before Steam read it, like a press shorter
 * than Steam's read cycle (HookupReportKind::loses_change). Reports of kinds that don't stream are never replaced.
 * (Before, reports went into a small socket queue: when Steam read slowly it filled up, the NEWEST reports were the
 * ones dropped and Steam read old ones -- a press could reach it one or more of its read cycles late.)
 */
struct HookupQueue {
  struct Entry {
    int kind;            // index in kinds, -1 = beyond the 4 kinds tracked (always kept)
    bool kept;           // never replaced or dropped before Steam reads it
    uint32_t length;
    uint64_t arrived_us;
    uint8_t data[HOOKUP_REPORT_MAX];
  };
  static constexpr int MAX = 16;
  std::mutex lock;
  Entry entries[MAX];
  int n = 0;
  HookupReportKind kinds[4];
  int nkinds = 0;
  bool token = false;    // the "something to read" byte is in Steam's socket
  bool closed = false;   // the report thread ended (controller gone)
  uint64_t press_at_arrival = 0;   // latency meter: arrival time of the entry that carries a new press
  // 10 s summary
  uint32_t arrived = 0, handed = 0, replaced = 0, lost = 0;
  uint64_t wait_sum_us = 0, wait_max_us = 0;
};

/** Steam process, as Steam reads a report from the mailbox: step 1 of the latency meter, and the start of step 2. */
__attribute__((visibility("hidden"))) static void hookup_meter_handed(HookupQueue &q, const HookupQueue::Entry &e,
                                                                      uint64_t now) {
  uint64_t wait = now - e.arrived_us;
  q.handed++;
  q.wait_sum_us += wait;
  if (wait > q.wait_max_us) q.wait_max_us = wait;
  HookupReportKind *k = e.kind >= 0 ? &q.kinds[e.kind] : nullptr;
  if (!k || !k->has_given || !k->press(e.data, k->given)) return;
  static HookupLatency stat;
  stat.add("button press waited for Steam to read it", wait, now);
  g_hookup_press_us.store(now, std::memory_order_release);
  int sample = g_hookup_samples.load(std::memory_order_relaxed);
  if (sample < 12) Logger::log("latency: press %d: Steam read it %.1f ms after it arrived\n", sample + 1, wait / 1000.0);
}

/** Steam's read() of a hooked-up node: the next report from the mailbox (see HookupQueue). */
__attribute__((visibility("hidden"))) static ssize_t hookup_read_steam(int fd, HookupQueue &q, void *buf, size_t count) {
  hookup_boost_this_thread("reads a hooked-up controller");
  for (;;) {
    {
      std::lock_guard<std::mutex> guard(q.lock);
      if (q.n) {
        HookupQueue::Entry e = q.entries[0];
        for (int i = 0; i < q.n - 1; i++) q.entries[i] = q.entries[i + 1];
        q.n--;
        if (!q.n && q.token) {  // nothing left: take the token back so poll() reports "nothing to read"
          uint8_t token;
          if (recv(fd, &token, 1, MSG_DONTWAIT) < 0) {}
          q.token = false;
        }
        size_t copied = std::min<size_t>(count, e.length);
        memcpy(buf, e.data, copied);
        hookup_meter_handed(q, e, monotonic_us());
        if (e.kind >= 0) {
          memcpy(q.kinds[e.kind].given, e.data, e.length);
          q.kinds[e.kind].has_given = true;
        }
        return static_cast<ssize_t>(copied);
      }
      if (q.closed) return 0;  // the controller is gone: end of file, as on a real node
    }
    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0 && (flags & O_NONBLOCK)) {
      errno = EAGAIN;
      return -1;
    }
    struct pollfd p = {fd, POLLIN, 0};
    if (syscall(SYS_ppoll, &p, 1, nullptr, nullptr, 0) < 0 && errno != EINTR) return -1;  // until there is something
    if (p.revents & (POLLHUP | POLLERR)) {
      std::lock_guard<std::mutex> guard(q.lock);
      if (!q.n) return 0;
    }
  }
}

__attribute__((visibility("hidden"))) static void *hookup_report_thread(void *arg) {
  auto *holder = static_cast<std::shared_ptr<DeckHidraw> *>(arg);
  std::shared_ptr<DeckHidraw> self = *holder;
  delete holder;
  HookupSlot *s = hookup_slot(self->hookup);
  std::shared_ptr<HookupQueue> qp = self->hookup_in;
  HookupQueue &q = *qp;
  hookup_boost_this_thread("hands controller reports to Steam");
  uint64_t next = s ? __atomic_load_n(&s->in_write, __ATOMIC_ACQUIRE) : 0;
  uint64_t meter_us = monotonic_us();
  auto kind_of = [&](const uint8_t *d, uint32_t length) {
    for (int i = 0; i < q.nkinds; i++)
      if (q.kinds[i].length == length && q.kinds[i].id == d[0]) return i;
    if (q.nkinds == 4) return -1;
    HookupReportKind &k = q.kinds[q.nkinds];
    k.length = length;
    k.id = d[0];
    hookup_descriptor_buttons(*s, d[0], k.buttons, length);       // report IDs: byte 0 is the ID
    uint8_t no_ids[HOOKUP_REPORT_MAX] = {};
    hookup_descriptor_buttons(*s, 0, no_ids, length);              // no IDs: the report starts at once
    for (uint32_t i = 0; i < length; i++) k.buttons[i] |= no_ids[i];
    return q.nkinds++;
  };
  bool peer_gone = false;
  while (s && __atomic_load_n(&s->present, __ATOMIC_ACQUIRE) &&
         __atomic_load_n(&s->generation, __ATOMIC_ACQUIRE) == self->hookup_generation) {
    uint64_t written = __atomic_load_n(&s->in_write, __ATOMIC_ACQUIRE);
    if (written - next > HOOKUP_IN_FIFO) next = written - HOOKUP_IN_FIFO;  // fell behind: skip the oldest
    while (next < written) {
      const HookupReport &r = s->in[next % HOOKUP_IN_FIFO];
      HookupQueue::Entry e;
      uint32_t length = __atomic_load_n(&r.length, __ATOMIC_RELAXED);
      if (length > HOOKUP_REPORT_MAX) length = HOOKUP_REPORT_MAX;
      memcpy(e.data, r.data, length);
      __atomic_thread_fence(__ATOMIC_ACQUIRE);
      bool intact = __atomic_load_n(&r.seq, __ATOMIC_ACQUIRE) == next + 1;
      next++;
      if (!intact || !length) continue;
      uint64_t now = monotonic_us();
      e.length = length;
      e.arrived_us = now;
      std::lock_guard<std::mutex> guard(q.lock);
      q.arrived++;
      e.kind = kind_of(e.data, length);
      HookupReportKind *k = e.kind >= 0 ? &q.kinds[e.kind] : nullptr;
      e.kept = !k;
      if (k) k->learn(e.data, now);
      // the newest replaceable report of the same kind waiting, and what Steam has / will get before it
      int last = -1;
      for (int i = q.n - 1; i >= 0 && k && k->learned; i--)
        if (q.entries[i].kind == e.kind && !q.entries[i].kept) { last = i; break; }
      bool replaced = false;
      if (last >= 0) {
        const uint8_t *base = nullptr;
        for (int i = last - 1; i >= 0 && !base; i--)
          if (q.entries[i].kind == e.kind) base = q.entries[i].data;
        if (!base && k->has_given) base = k->given;
        if (base && !k->loses_change(q.entries[last].data, e.data, base)) {
          q.entries[last] = e;  // latest wins
          q.replaced++;
          replaced = true;
        } else {
          q.entries[last].kept = true;  // it carries a change the new one undoes: it must reach Steam
        }
      }
      if (!replaced) {
        if (q.n == HookupQueue::MAX) {  // Steam stopped reading for a while: make room, oldest replaceable first
          int drop = 0;
          for (int i = 0; i < q.n; i++)
            if (!q.entries[i].kept) { drop = i; break; }
          if (!q.entries[drop].kept) q.replaced++;
          else if (q.entries[drop].kind >= 0 && q.kinds[q.entries[drop].kind].learned) q.lost++;
          for (int i = drop; i < q.n - 1; i++) q.entries[i] = q.entries[i + 1];
          q.n--;
        }
        q.entries[q.n++] = e;
      }
      if (!q.token && !peer_gone) {  // tell Steam's poll() there is something to read
        uint8_t token = 1;
        if (send(self->peer, &token, 1, MSG_DONTWAIT | MSG_NOSIGNAL) == 1) q.token = true;
        else if (errno != EAGAIN && errno != EWOULDBLOCK) peer_gone = true;
      }
    }
    if (peer_gone) break;  // Steam closed the node
    // 10 s summary, logged when Steam was slow to read (replacing reports, or reading them late)
    uint64_t now_us = monotonic_us();
    if (now_us - meter_us >= 10000000ULL) {
      std::lock_guard<std::mutex> guard(q.lock);
      double secs = (now_us - meter_us) / 1e6;
      if (q.replaced || q.lost || (q.handed && q.wait_sum_us / q.handed > 2000))
        Logger::log("hookup: /dev/hidraw%u: %.0f reports/s from the controller, Steam read %.0f/s, each the newest "
                    "(avg %.1f ms after it arrived, max %.1f ms); %u replaced by a newer one while Steam was busy%s\n",
                    HOOKUP_MINOR_BASE + self->hookup, q.arrived / secs, q.handed / secs,
                    q.handed ? q.wait_sum_us / 1000.0 / q.handed : 0.0, q.wait_max_us / 1000.0, q.replaced,
                    q.lost ? " -- Steam stopped reading for a while, some short presses were dropped" : "");
      q.arrived = q.handed = q.replaced = q.lost = 0;
      q.wait_sum_us = q.wait_max_us = 0;
      meter_us = now_us;
    }
    // Sleep until the next report. The SDL3 bridge's fast path wakes this futex the moment it writes one (the
    // low half of in_write changes); reports relayed by DroidDeck's app are picked up by the timeout.
    uint64_t beat = __atomic_load_n(&s->direct_ms, __ATOMIC_ACQUIRE);
    bool fast = beat && monotonic_us() / 1000 - beat < 1500;
    struct timespec wait = {0, (fast ? 4000L : 500L) * 1000L};
    syscall(SYS_futex, reinterpret_cast<uint32_t *>(&s->in_write), HOOKUP_FUTEX_WAIT, static_cast<uint32_t>(written),
            &wait, nullptr, 0);
  }
  {
    std::lock_guard<std::mutex> guard(q.lock);
    q.closed = true;
  }
  syscall(SYS_close, self->peer);
  return nullptr;
}

__attribute__((visibility("hidden"))) static int open_hookup_hidraw(int flags, int slot) {
  HookupSlot *s = hookup_slot(slot);
  if (!s || !process_is_steam_client()) {
    errno = ENOENT;
    return -1;
  }
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) < 0) return -1;
  // The socket only carries the mailbox's 1-byte "something to read" token (see HookupQueue): small is plenty.
  int buffer = HOOKUP_REPORT_MAX * 4;
  setsockopt(pair[1], SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
  if (!(flags & O_CLOEXEC)) fcntl(pair[0], F_SETFD, 0);
  if (flags & O_NONBLOCK) fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL) | O_NONBLOCK);
  auto pad = std::make_shared<DeckHidraw>();
  pad->peer = pair[1];
  pad->hookup = static_cast<int8_t>(slot);
  pad->hookup_generation = __atomic_load_n(&s->generation, __ATOMIC_ACQUIRE);
  pad->hookup_in = std::make_shared<HookupQueue>();
  {
    std::lock_guard<std::recursive_mutex> guard(controller_mutex());
    deck_map()[pair[0]] = pad;
    watch_fd(pair[0]);
  }
  pthread_t thread;
  auto *arg = new std::shared_ptr<DeckHidraw>(pad);
  if (pthread_create(&thread, nullptr, hookup_report_thread, arg) != 0) {
    delete arg;
    std::lock_guard<std::recursive_mutex> guard(controller_mutex());
    deck_map().erase(pair[0]);
    unwatch_fd(pair[0]);
    syscall(SYS_close, pair[0]);
    syscall(SYS_close, pair[1]);
    errno = ENOMEM;
    return -1;
  }
  pthread_detach(thread);
  Logger::log("hookup: /dev/hidraw%u opened as fd %d (%04x:%04x \"%s\")\n", HOOKUP_MINOR_BASE + slot, pair[0], s->vendor,
              s->product, s->name);
  return pair[0];
}

/**
 * Steam -> controller: an output report (kind 0) or a feature-report write (kind 1). Called without the hook's
 * controller lock (see the write() patch), so a wait here never holds up Steam's other controller calls -- its
 * virtual pad above all. Output reports (rumble, lights) wait at most a few ms for room: when the controller can't
 * take them that fast the newest is dropped, as the next one carries the current state again.
 */
__attribute__((visibility("hidden"))) static void hookup_queue(const DeckHidraw &pad, const uint8_t *data, size_t size,
                                                               uint32_t kind) {
  HookupSlot *s = hookup_slot(pad.hookup);
  if (!s || !data || !size || !__atomic_load_n(&s->present, __ATOMIC_ACQUIRE)) return;
  if (size > HOOKUP_REPORT_MAX) size = HOOKUP_REPORT_MAX;
  static std::mutex one_at_a_time;
  std::lock_guard<std::mutex> guard(one_at_a_time);
  static HookupOutputStat stats[HOOKUP_SLOTS];
  HookupOutputStat &st = stats[pad.hookup];
  uint64_t t0 = monotonic_us();
  uint64_t idx = __atomic_load_n(&s->out_write, __ATOMIC_RELAXED);
  int limit = (kind ? HOOKUP_OUTPUT_WAIT_MS : HOOKUP_REPORT_WAIT_MS) * 4;
  int waited = 0;
  for (; idx - __atomic_load_n(&s->out_read, __ATOMIC_ACQUIRE) >= HOOKUP_OUT_FIFO && waited < limit; waited++)
    sleep_us(250);
  uint64_t t1 = monotonic_us();
  if (waited) st.waited_us += t1 - t0;
  if (!st.since_us) st.since_us = t1;
  if (kind) st.features++; else st.reports++;
  bool full = idx - __atomic_load_n(&s->out_read, __ATOMIC_ACQUIRE) >= HOOKUP_OUT_FIFO;
  if (full && !kind) st.dropped++;
  if (t1 - st.since_us >= 10000000ULL) {
    if (st.waited_us || st.dropped)
      Logger::log("hookup: /dev/hidraw%u: Steam sent %u output reports + %u feature writes in 10 s; the controller "
                  "fell behind: waited %.1f ms for room, dropped %u output reports\n",
                  HOOKUP_MINOR_BASE + pad.hookup, st.reports, st.features, st.waited_us / 1000.0, st.dropped);
    st = HookupOutputStat{};
    st.since_us = t1;
  }
  if (full && !kind) return;
  HookupReport &r = s->out[idx % HOOKUP_OUT_FIFO];
  __atomic_store_n(&r.seq, 0, __ATOMIC_RELAXED);
  __atomic_thread_fence(__ATOMIC_RELEASE);
  r.length = static_cast<uint32_t>(size);
  r.kind = kind;
  memcpy(r.data, data, size);
  __atomic_thread_fence(__ATOMIC_RELEASE);
  __atomic_store_n(&r.seq, idx + 1, __ATOMIC_RELEASE);
  __atomic_store_n(&s->out_write, idx + 1, __ATOMIC_RELEASE);
}

/** Feature (or input) report read: asks the controller through the app and waits for the answer. */
__attribute__((visibility("hidden"))) static int hookup_get(const DeckHidraw &pad, uint8_t *buf, size_t size, bool input) {
  HookupSlot *s = hookup_slot(pad.hookup);
  if (!s || !buf || size < 1) {
    errno = EINVAL;
    return -1;
  }
  static std::mutex one_at_a_time[HOOKUP_SLOTS];
  std::lock_guard<std::mutex> guard(one_at_a_time[pad.hookup]);
  uint8_t report_id = buf[0];
  __atomic_store_n(&s->get_report_id, report_id | (input ? 0x100u : 0u), __ATOMIC_RELAXED);
  __atomic_store_n(&s->get_length, static_cast<int32_t>(std::min<size_t>(size, HOOKUP_REPORT_MAX)), __ATOMIC_RELAXED);
  uint64_t request = __atomic_add_fetch(&s->get_request, 1, __ATOMIC_RELEASE);
  uint64_t t0 = monotonic_us();
  for (int waited = 0; waited < HOOKUP_FEATURE_TIMEOUT_MS * 4; waited++) {
    if (!__atomic_load_n(&s->present, __ATOMIC_ACQUIRE)) break;
    if (__atomic_load_n(&s->get_reply, __ATOMIC_ACQUIRE) == request) {
      int32_t length = __atomic_load_n(&s->get_length, __ATOMIC_RELAXED);
      if (length <= 0 || length > HOOKUP_REPORT_MAX) break;
      size_t copied = std::min(size, static_cast<size_t>(length));
      memcpy(buf, s->get, copied);
      uint64_t took = monotonic_us() - t0;
      static std::atomic<unsigned> slow;
      if (took > 20000) {  // Steam waits for these: a slow one holds up that Steam thread
        unsigned n = ++slow;
        if ((n & (n - 1)) == 0)
          Logger::log("hookup: report 0x%02x read took %.1f ms (slow reads so far: %u)\n", report_id, took / 1000.0, n);
      }
      return static_cast<int>(copied);
    }
    sleep_us(250);
  }
  static std::atomic<unsigned> failures;
  unsigned n = ++failures;
  if ((n & (n - 1)) == 0) Logger::log("hookup: report 0x%02x read got no answer (x%u)\n", report_id, n);
  errno = EIO;
  return -1;
}

__attribute__((visibility("hidden"))) static int ioctl_hookup(DeckHidraw &pad, ioctl_request_t op, void *argp) {
  HookupSlot *s = hookup_slot(pad.hookup);
  if (_IOC_TYPE(op) != 'H' || !s) {
    errno = ENOTTY;
    return -1;
  }
  switch (_IOC_NR(op)) {
  case 0x01:
    *static_cast<int *>(argp) = static_cast<int>(std::min<uint32_t>(s->desc_len, HOOKUP_DESC_MAX));
    return 0;
  case 0x02: {
    auto *out = static_cast<uint8_t *>(argp);
    uint32_t size;
    memcpy(&size, out, sizeof(size));
    memcpy(out + 4, s->desc, std::min<size_t>(size, std::min<uint32_t>(s->desc_len, HOOKUP_DESC_MAX)));
    return 0;
  }
  case 0x03: {
    struct {
      uint32_t bustype;
      int16_t vendor;
      int16_t product;
    } info = {s->bus ? s->bus : static_cast<uint32_t>(BUS_USB), static_cast<int16_t>(s->vendor), static_cast<int16_t>(s->product)};
    memcpy(argp, &info, sizeof(info));
    return 0;
  }
  case 0x04: return copy_ioctl_string(op, argp, s->name);
  case 0x05: {
    char phys[48];
    snprintf(phys, sizeof(phys), "usb-droiddeck-%d/input%d", 10 + pad.hookup, s->iface < 0 ? 0 : s->iface);
    return copy_ioctl_string(op, argp, phys);
  }
  case 0x08: return copy_ioctl_string(op, argp, s->serial);
  case 0x06:  // HIDIOCSFEATURE
    hookup_queue(pad, static_cast<const uint8_t *>(argp), _IOC_SIZE(op), 1);
    return static_cast<int>(_IOC_SIZE(op));
  case 0x07:  // HIDIOCGFEATURE
    return hookup_get(pad, static_cast<uint8_t *>(argp), _IOC_SIZE(op), false);
  case 0x0A:  // HIDIOCGINPUT
    return hookup_get(pad, static_cast<uint8_t *>(argp), _IOC_SIZE(op), true);
  case 0x0B:  // HIDIOCSOUTPUT
    hookup_queue(pad, static_cast<const uint8_t *>(argp), _IOC_SIZE(op), 0);
    return static_cast<int>(_IOC_SIZE(op));
  default:
    errno = EINVAL;
    return -1;
  }
}

// ---- game rumble -> Steam (uinput force feedback) ----
__attribute__((visibility("hidden"))) static void hookup_ff_from_game(uint16_t slot, int strong, int weak, uint16_t length) {
  HookupHeader *h = hookup_header();
  if (!h || slot < UINPUT_EVENT_BASE || slot >= UINPUT_EVENT_LIMIT) return;
  if (!__atomic_load_n(&h->ff_to_steam, __ATOMIC_ACQUIRE)) return;
  HookupFF &f = h->ff[slot - UINPUT_EVENT_BASE];
  f.strong = strong;
  f.weak = weak;
  f.length = length;
  f.play = (strong || weak) && length ? 1 : 0;
  __atomic_add_fetch(&f.seq, 1, __ATOMIC_RELEASE);
}

/** Runs in the Steam client: turns game rumble into uinput force-feedback requests for Steam's virtual pad. */
__attribute__((visibility("hidden"))) static void hookup_ff_to_steam() {
  HookupHeader *h = hookup_header();
  if (!h) return;
  std::lock_guard<std::recursive_mutex> guard(controller_mutex());
  for (auto &entry : uinput_map()) {
    UinputWriter &w = *entry.second;
    if (!w.published || w.owner != getpid() || w.node < UINPUT_EVENT_BASE || w.node >= UINPUT_EVENT_LIMIT) continue;
    if (!test_bit(w.description.ffbits, sizeof(w.description.ffbits), FF_RUMBLE)) continue;
    HookupFF &f = h->ff[w.node - UINPUT_EVENT_BASE];
    uint64_t seq = __atomic_load_n(&f.seq, __ATOMIC_ACQUIRE);
    if (seq == w.ff_seen) continue;
    w.ff_seen = seq;
    struct timeval now = {};
    gettimeofday(&now, nullptr);
    auto event = [&](uint16_t type, uint16_t code, int32_t value) {
      struct input_event ev = {};
      ev.time = now;
      ev.type = type;
      ev.code = code;
      ev.value = value;
      w.ff_queue.push_back(ev);
    };
    if (f.play) {
      w.ff_request++;
      memset(&w.ff_effect, 0, sizeof(w.ff_effect));
      w.ff_effect.type = FF_RUMBLE;
      w.ff_effect.id = 0;
      w.ff_effect.replay.length = f.length == 0xffff ? 0 : static_cast<uint16_t>(f.length);
      w.ff_effect.u.rumble.strong_magnitude = static_cast<uint16_t>(std::max(0, std::min(65535, f.strong)));
      w.ff_effect.u.rumble.weak_magnitude = static_cast<uint16_t>(std::max(0, std::min(65535, f.weak)));
      event(EV_UINPUT, UI_FF_UPLOAD, static_cast<int32_t>(w.ff_request));
      event(EV_FF, 0, 1);
    } else {
      event(EV_FF, 0, 0);
    }
    uint64_t one = 1;
    if (syscall(SYS_write, entry.first, &one, sizeof(one)) < 0) {}
  }
}

/** Serves Steam's read() of its uinput fd: the queued force-feedback requests. -2 = not handled. */
__attribute__((visibility("hidden"))) static ssize_t hookup_read_uinput(int fd, void *buf, size_t count) {
  std::unique_lock<std::recursive_mutex> guard(controller_mutex());
  auto made = uinput_map().find(fd);
  if (made == uinput_map().end()) {
    // Steam reading a hooked-up controller: answered from its mailbox (HookupQueue), unlocked
    auto deck = deck_map().find(fd);
    if (deck == deck_map().end()) return -2;
    if (deck->second->hookup < 0 || !deck->second->hookup_in) {  // one of DroidDeck's own pads
      hookup_boost_this_thread("reads DroidDeck's controller");
      return -2;
    }
    std::shared_ptr<HookupQueue> q = deck->second->hookup_in;
    guard.unlock();
    return hookup_read_steam(fd, *q, buf, count);
  }
  std::shared_ptr<UinputWriter> w = made->second;
  if (count < sizeof(struct input_event)) {
    errno = EINVAL;
    return -1;
  }
  for (;;) {
    if (!w->ff_queue.empty()) {
      size_t n = std::min(count / sizeof(struct input_event), w->ff_queue.size());
      for (size_t i = 0; i < n; i++) {
        memcpy(static_cast<uint8_t *>(buf) + i * sizeof(struct input_event), &w->ff_queue.front(), sizeof(struct input_event));
        w->ff_queue.pop_front();
      }
      // The eventfd counter mirrors "events pending": drained when the queue empties, kept >0 otherwise,
      // so Steam's poll() on the fd stays accurate.
      int flags = fcntl(fd, F_GETFL);
      if (w->ff_queue.empty()) {
        uint64_t counter;
        if (flags >= 0 && !(flags & O_NONBLOCK)) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        if (syscall(SYS_read, fd, &counter, sizeof(counter)) < 0) {}
        if (flags >= 0 && !(flags & O_NONBLOCK)) fcntl(fd, F_SETFL, flags);
      } else {
        uint64_t one = 1;
        if (syscall(SYS_write, fd, &one, sizeof(one)) < 0) {}
      }
      return static_cast<ssize_t>(n * sizeof(struct input_event));
    }
    int flags = fcntl(fd, F_GETFL);
    if (flags >= 0 && (flags & O_NONBLOCK)) {
      errno = EAGAIN;
      return -1;
    }
    guard.unlock();
    uint64_t counter;
    if (syscall(SYS_read, fd, &counter, sizeof(counter)) < 0 && errno != EINTR) return -1;  // blocks until queued
    guard.lock();
  }
}

// ---- hot-plug: udev add/remove for the hooked-up nodes, plus the force-feedback pump ----
__attribute__((visibility("hidden"))) static void *hookup_watch_thread(void *) {
  uint32_t seen_gen[HOOKUP_SLOTS] = {};
  bool seen[HOOKUP_SLOTS] = {};
  char devpath[HOOKUP_SLOTS][160] = {};
  for (unsigned tick = 0;; tick++) {
    sleep_us(2000);
    hookup_ff_to_steam();
    if (tick % 10) continue;
    for (int i = 0; i < HOOKUP_SLOTS; i++) {
      HookupSlot *s = hookup_slot(i);
      if (!s) continue;
      bool now = __atomic_load_n(&s->present, __ATOMIC_ACQUIRE) != 0;
      uint32_t gen = __atomic_load_n(&s->generation, __ATOMIC_ACQUIRE);
      if (now == seen[i] && (!now || gen == seen_gen[i])) continue;
      char path[32];
      snprintf(path, sizeof(path), "/dev/hidraw%u", HOOKUP_MINOR_BASE + i);
      if (seen[i]) {
        int sent = inject_uevent("remove", devpath[i], "hidraw", path, DECK_HIDRAW_MAJOR, HOOKUP_MINOR_BASE + i);
        Logger::log("hookup: %s removed (udev event to %d monitors)\n", path, sent);
      }
      seen[i] = now;
      seen_gen[i] = gen;
      if (now) {
        hookup_devpath(i, *s, devpath[i], sizeof(devpath[i]));
        if (seen_gen[i] != 0) {
          struct timespec settle = {0, 200 * 1000 * 1000};
          nanosleep(&settle, nullptr);
        }
        int sent = inject_uevent("add", devpath[i], "hidraw", path, DECK_HIDRAW_MAJOR, HOOKUP_MINOR_BASE + i);
        Logger::log("hookup: %s is %04x:%04x \"%s\" (udev event to %d monitors)\n", path, s->vendor, s->product, s->name, sent);
      }
      poke_hidraw_watchers(HOOKUP_MINOR_BASE + i);
    }
  }
  return nullptr;
}

__attribute__((constructor)) static void start_hookup_watch() {
  config();
  if (!process_is_steam_client() || !fake_deck_enabled()) return;
  const char *path = getenv("FAKE_HOOKUP_SHM");
  if (!path || !*path) {
    Logger::log("hookup: off (no FAKE_HOOKUP_SHM: the SDL3 bridge app is not installed, or an older DroidDeck build)\n");
    return;
  }
  if (!hookup_shm()) return;
  Logger::log("hookup: watching %s for controllers handed over by the SDL3 bridge\n", path);
  pthread_t thread;
  if (pthread_create(&thread, nullptr, hookup_watch_thread, nullptr) == 0) pthread_detach(thread);
}
// =================== end sdl3bridge: Steam Native Hook-up ===================

