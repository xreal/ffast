const std = @import("std");

pub const ThrottleState = enum { normal, high, critical };

pub const PauseReason = enum { none, high_watermark, critical_watermark };

pub const Config = struct {
    max_ram_mb: u32 = 3800,
    high_watermark_pct: u8 = 85,
    critical_watermark_pct: u8 = 95,
};

pub const AdmitResult = struct {
    allowed: bool,
    reason: PauseReason,
    sleep_ns: u64,
};

pub const ResourceGovernor = struct {
    cfg: Config,
    rss_bytes: std.atomic.Value(u64),

    pub fn init(cfg: Config) ResourceGovernor {
        return .{ .cfg = cfg, .rss_bytes = std.atomic.Value(u64).init(0) };
    }

    pub fn updateRssBytes(self: *ResourceGovernor, rss: u64) void {
        self.rss_bytes.store(rss, .release);
    }

    pub fn state(self: *const ResourceGovernor) ThrottleState {
        const rss = self.rss_bytes.load(.acquire);
        const cap = @as(u64, self.cfg.max_ram_mb) * 1024 * 1024;
        if (rss >= cap * self.cfg.critical_watermark_pct / 100) return .critical;
        if (rss >= cap * self.cfg.high_watermark_pct / 100) return .high;
        return .normal;
    }

    pub fn tryAdmitBatch(self: *ResourceGovernor, estimated_bytes: u64) AdmitResult {
        const rss = self.rss_bytes.load(.acquire);
        const cap = @as(u64, self.cfg.max_ram_mb) * 1024 * 1024;
        const current_state = self.state();
        if (current_state == .critical or rss + estimated_bytes >= cap) return .{ .allowed = false, .reason = .critical_watermark, .sleep_ns = 200 * std.time.ns_per_ms };
        if (current_state == .high) return .{ .allowed = false, .reason = .high_watermark, .sleep_ns = 50 * std.time.ns_per_ms };
        return .{ .allowed = true, .reason = .none, .sleep_ns = 0 };
    }
};
