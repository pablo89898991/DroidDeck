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
// Where a button press of a hooked-up controller spends its time: from the moment its report is handed to Steam
// to Steam's virtual pad (Steam's own processing), and from there to the game reading it. Mouse / keyboard
// output from Steam does not go through the virtual pad, so it is not part of either number.
struct HookupLatency {
  std::mutex lock;
  uint32_t n = 0;
  uint64_t sum_us = 0, max_us = 0, since_us = 0;
  void add(const char *what, uint64_t us, uint64_t now_us) {
    std::lock_guard<std::mutex> guard(lock);
    if (!since_us) since_us = now_us;
    n++;
    sum_us += us;
    if (us > max_us) max_us = us;
    if (now_us - since_us < 10000000ULL) return;
    Logger::log("latency: %s: %u presses, avg %.1f ms, max %.1f ms\n", what, n, sum_us / 1000.0 / n, max_us / 1000.0);
    n = 0;
    sum_us = max_us = 0;
    since_us = now_us;
  }
};
static std::atomic<uint64_t> g_hookup_press_us{0};   // Steam process: a press handed to Steam, not yet on its pad

/** Digital buttons of a Sony controller's USB input report (DualSense / Edge, DualShock 4); 0 = layout unknown. */
__attribute__((visibility("hidden"))) static uint32_t hookup_buttons(const HookupSlot &s, const uint8_t *d, uint32_t n) {
  if (s.vendor != 0x054c || n < 11 || d[0] != 0x01) return 0;
  if (s.product == 0x0ce6 || s.product == 0x0df2)  // DualSense, DualSense Edge
    return 0x80000000u | ((d[8] & 0x0f) != 8 ? 1u : 0u) | (d[8] & 0xf0u) | (uint32_t)d[9] << 8 | (uint32_t)(d[10] & 0xf7) << 16;
  if (s.product == 0x05c4 || s.product == 0x09cc)  // DualShock 4
    return 0x80000000u | ((d[5] & 0x0f) != 8 ? 1u : 0u) | (d[5] & 0xf0u) | (uint32_t)d[6] << 8 | (uint32_t)(d[7] & 0x03) << 16;
  return 0;
}

/** Steam process, as Steam writes its virtual pad: a key press now = the press handed to Steam earlier. */
__attribute__((visibility("hidden"))) static void hookup_meter_virtual_pad(const std::vector<struct input_event> &events) {
  uint64_t press = g_hookup_press_us.load(std::memory_order_acquire);
  if (!press) return;
  uint64_t now = monotonic_us();
  if (now - press > 1000000ULL) {  // never reached the pad (mapped to mouse / keyboard, or nothing)
    g_hookup_press_us.compare_exchange_strong(press, 0);
    return;
  }
  for (const struct input_event &ev : events) {
    if (ev.type != EV_KEY || ev.value != 1) continue;
    if (!g_hookup_press_us.compare_exchange_strong(press, 0)) return;
    static HookupLatency stat;
    stat.add("button press -> Steam's virtual pad", now - press, now);
    return;
  }
}

/** Game process, as it reads Steam's virtual pad: how long a key press waited there (stamped when Steam wrote it). */
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

__attribute__((visibility("hidden"))) static void *hookup_report_thread(void *arg) {
  auto *holder = static_cast<std::shared_ptr<DeckHidraw> *>(arg);
  std::shared_ptr<DeckHidraw> self = *holder;
  delete holder;
  HookupSlot *s = hookup_slot(self->hookup);
  uint64_t next = s ? __atomic_load_n(&s->in_write, __ATOMIC_ACQUIRE) : 0;
  unsigned unread = 0;
  uint64_t meter_us = monotonic_us();
  uint32_t buttons_was = 0;
  while (s && __atomic_load_n(&s->present, __ATOMIC_ACQUIRE) &&
         __atomic_load_n(&s->generation, __ATOMIC_ACQUIRE) == self->hookup_generation) {
    uint64_t written = __atomic_load_n(&s->in_write, __ATOMIC_ACQUIRE);
    if (written - next > HOOKUP_IN_FIFO) next = written - HOOKUP_IN_FIFO;  // fell behind: skip the oldest
    bool failed = false;
    while (next < written) {
      const HookupReport &r = s->in[next % HOOKUP_IN_FIFO];
      uint8_t data[HOOKUP_REPORT_MAX];
      uint32_t length = __atomic_load_n(&r.length, __ATOMIC_RELAXED);
      if (length > HOOKUP_REPORT_MAX) length = HOOKUP_REPORT_MAX;
      memcpy(data, r.data, length);
      __atomic_thread_fence(__ATOMIC_ACQUIRE);
      bool intact = __atomic_load_n(&r.seq, __ATOMIC_ACQUIRE) == next + 1;
      next++;
      if (!intact || !length) continue;
      uint32_t buttons = hookup_buttons(*s, data, length);
      if (buttons & ~buttons_was & 0x7fffffffu) {
        uint64_t none = 0;
        g_hookup_press_us.compare_exchange_strong(none, monotonic_us());
      }
      buttons_was = buttons;
      if (send(self->peer, data, length, MSG_DONTWAIT | MSG_NOSIGNAL) < 0) {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
          failed = true;
          break;
        }
        unread++;  // Steam has not read the previous reports yet
      }
    }
    if (failed) break;
    // Lag meter: reports Steam did not read in time (its socket was full), logged every 10 s when it happened.
    uint64_t now_us = monotonic_us();
    if (now_us - meter_us >= 10000000ULL) {
      if (unread)
        Logger::log("hookup: /dev/hidraw%u: Steam read too slowly, %u reports not taken in the last 10 s\n",
                    HOOKUP_MINOR_BASE + self->hookup, unread);
      unread = 0;
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
  // Small, like DroidDeck's own controller nodes (about 6 reports): when Steam reads slower than the controller
  // sends, it gets near-current input instead of working through a long line of old reports.
  int buffer = HOOKUP_REPORT_MAX * 4;
  setsockopt(pair[1], SOL_SOCKET, SO_SNDBUF, &buffer, sizeof(buffer));
  if (!(flags & O_CLOEXEC)) fcntl(pair[0], F_SETFD, 0);
  if (flags & O_NONBLOCK) fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL) | O_NONBLOCK);
  auto pad = std::make_shared<DeckHidraw>();
  pad->peer = pair[1];
  pad->hookup = static_cast<int8_t>(slot);
  pad->hookup_generation = __atomic_load_n(&s->generation, __ATOMIC_ACQUIRE);
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
  if (made == uinput_map().end()) return -2;
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

