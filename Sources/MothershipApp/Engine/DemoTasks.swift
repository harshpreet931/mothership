import Foundation
import GitKit
import ShipModel

/// Believable tasks, runs, diffs and PRs for `MOTHERSHIP_DEMO=1`: a Best-of-3 still in
/// flight, a Best-of-2 where one run was kept, and PRs in every state.
@MainActor
enum DemoTasks {
    /// Creates the run workspaces (after the seeded ones, so the demo engine's run scripts
    /// bind to them in order) and fills `tasks`, `pullRequests` and the diff fixtures.
    static func seed(_ model: AppModel, home: String, existing: (String) -> String, named: [String: WorkspaceID]) {
        let api = home + "/code/api-gateway"
        let web = home + "/code/web-dashboard"
        func run(_ name: String, cwd: String) -> WorkspaceID {
            model.createWorkspace(cwd: existing(cwd), name: name, focus: false, insertAfterSelection: false).0.id
        }

        let headersClaude = run("rate-limit-headers · claude", cwd: home)
        let headersCodex = run("rate-limit-headers · codex", cwd: home)
        let headersGemini = run("rate-limit-headers · gemini", cwd: home)
        let flakyClaude = run("flaky-checkout · claude", cwd: home)
        let flakyOpenCode = run("flaky-checkout · opencode", cwd: home)

        let headers = AgentTask(
            id: UUID(uuidString: "6E0C2A4B-1111-4C55-9F00-000000000001") ?? UUID(),
            title: "Rate-limit headers on every response",
            prompt: "Return X-RateLimit-Limit, X-RateLimit-Remaining and Retry-After on every API response, with tests, and document them.",
            repoRoot: api, baseBranch: "main", createdAt: Date().addingTimeInterval(-26 * 60),
            runs: [
                TaskRun(
                    id: runIDs.claude, agent: .claude, branch: "mship/rate-limit-headers-claude",
                    worktreePath: api + "/.mothership/worktrees/rate-limit-headers-claude", workspaceID: headersClaude,
                    diff: DiffStat(files: [
                        FileChange(path: "internal/middleware/ratelimit.go", status: .modified, insertions: 8, deletions: 3),
                        FileChange(path: "internal/middleware/headers.go", status: .added, insertions: 18, deletions: 0),
                        FileChange(path: "internal/middleware/ratelimit_test.go", status: .modified, insertions: 23, deletions: 0),
                        FileChange(path: "docs/api/rate-limits.md", status: .modified, insertions: 11, deletions: 2),
                    ]),
                    outcome: .running
                ),
                TaskRun(
                    id: runIDs.codex, agent: .codex, branch: "mship/rate-limit-headers-codex",
                    worktreePath: api + "/.mothership/worktrees/rate-limit-headers-codex", workspaceID: headersCodex,
                    diff: DiffStat(files: [
                        FileChange(path: "internal/middleware/ratelimit.go", status: .modified, insertions: 52, deletions: 11),
                        FileChange(path: "internal/middleware/ratelimit_test.go", status: .modified, insertions: 27, deletions: 4),
                        FileChange(path: "api/openapi.yaml", status: .modified, insertions: 41, deletions: 0),
                    ]),
                    outcome: .running
                ),
                TaskRun(
                    id: runIDs.gemini, agent: .gemini, branch: "mship/rate-limit-headers-gemini",
                    worktreePath: api + "/.mothership/worktrees/rate-limit-headers-gemini", workspaceID: headersGemini,
                    diff: DiffStat(files: [
                        FileChange(path: "internal/middleware/ratelimit.go", status: .modified, insertions: 96, deletions: 58),
                        FileChange(path: "internal/limiter/window.go", status: .modified, insertions: 22, deletions: 17),
                        FileChange(path: "internal/limiter/window_test.go", status: .modified, insertions: 9, deletions: 1),
                        FileChange(path: "internal/limiter/legacy.go", status: .deleted, insertions: 0, deletions: 64),
                        FileChange(path: "go.mod", status: .modified, insertions: 1, deletions: 0),
                    ]),
                    outcome: .running
                ),
            ]
        )
        let flaky = AgentTask(
            id: UUID(uuidString: "6E0C2A4B-2222-4C55-9F00-000000000002") ?? UUID(),
            title: "Fix the flaky checkout test",
            prompt: "checkout.spec.ts fails about one run in ten on CI. Find the race and fix it properly.",
            repoRoot: web, baseBranch: "main", createdAt: Date().addingTimeInterval(-74 * 60),
            runs: [
                TaskRun(
                    id: runIDs.flakyClaude, agent: .claude, branch: "mship/flaky-checkout-claude",
                    worktreePath: web + "/.mothership/worktrees/flaky-checkout-claude", workspaceID: flakyClaude,
                    diff: DiffStat(files: [
                        FileChange(path: "e2e/checkout.spec.ts", status: .modified, insertions: 3, deletions: 2),
                        FileChange(path: "src/cart/useCart.ts", status: .modified, insertions: 3, deletions: 2),
                    ]),
                    outcome: .kept
                ),
                TaskRun(
                    id: runIDs.flakyOpenCode, agent: .opencode, branch: "mship/flaky-checkout-opencode",
                    worktreePath: web + "/.mothership/worktrees/flaky-checkout-opencode", workspaceID: flakyOpenCode,
                    diff: DiffStat(files: [
                        FileChange(path: "e2e/checkout.spec.ts", status: .modified, insertions: 4, deletions: 1),
                        FileChange(path: "playwright.config.ts", status: .modified, insertions: 1, deletions: 1),
                    ]),
                    outcome: .running
                ),
            ]
        )
        model.tasks = [headers, flaky]

        var pullRequests: [WorkspaceID: PullRequestStatus] = [:]
        if let id = named["mothership"] {
            pullRequests[id] = PullRequestStatus(
                number: 128, title: "Make token refresh testable with an injected clock", url: "https://github.com/acme/mothership/pull/128",
                state: .open, checks: .passing, review: .approved
            )
        }
        if let id = named["web-dashboard"] {
            pullRequests[id] = PullRequestStatus(
                number: 131, title: "API reference generated from openapi.yaml", url: "https://github.com/acme/web-dashboard/pull/131",
                state: .draft, checks: .pending, review: .none
            )
        }
        if let id = named["api-gateway"] {
            pullRequests[id] = PullRequestStatus(
                number: 127, title: "Sliding-window limiter: stop double counting retries", url: "https://github.com/acme/api-gateway/pull/127",
                state: .open, checks: .failing, review: .changesRequested
            )
        }
        if let id = named["infra"] {
            pullRequests[id] = PullRequestStatus(
                number: 120, title: "CloudFront cache policy for /assets", url: "https://github.com/acme/infra/pull/120",
                state: .merged, checks: .passing, review: .approved
            )
        }
        pullRequests[flakyClaude] = PullRequestStatus(
            number: 134, title: "Fix the checkout race: wait for the cart, not the clock", url: "https://github.com/acme/web-dashboard/pull/134",
            state: .open, checks: .passing, review: .reviewRequired
        )
        model.pullRequests = pullRequests
        model.collapsedTasks = []
        let stats = Dictionary(uniqueKeysWithValues: model.tasks.flatMap(\.runs).map { ($0.id, $0.diff ?? .empty) })
        model.diffFixture = { runID in diff(for: runID) ?? stats[runID].map(synthesized) }
    }

    static let runIDs = (
        claude: UUID(uuidString: "6E0C2A4B-1111-4C55-9F00-0000000000C1") ?? UUID(),
        codex: UUID(uuidString: "6E0C2A4B-1111-4C55-9F00-0000000000C2") ?? UUID(),
        gemini: UUID(uuidString: "6E0C2A4B-1111-4C55-9F00-0000000000C3") ?? UUID(),
        flakyClaude: UUID(uuidString: "6E0C2A4B-2222-4C55-9F00-0000000000C1") ?? UUID(),
        flakyOpenCode: UUID(uuidString: "6E0C2A4B-2222-4C55-9F00-0000000000C2") ?? UUID()
    )

    // MARK: Diffs

    static func diff(for runID: UUID) -> String? {
        switch runID {
        case runIDs.claude: claudeHeadersDiff
        case runIDs.flakyClaude: flakyDiff
        default: nil
        }
    }

    /// A plausible diff whose counts match a run's `DiffStat` exactly.
    static func synthesized(_ stat: DiffStat) -> String {
        let go = ["\tlimit := cfg.Limit", "\tif remaining < 0 {", "\t\tremaining = 0", "\t}", "\treturn decision, nil",
                  "\tw.Header().Set(\"X-RateLimit-Limit\", strconv.Itoa(limit))", "\tlog.Debug(\"rate limit\", \"key\", key)",
                  "\twindow := l.window(key, now)", "\tdecision.ResetAt = window.End()"]
        let yaml = ["        X-RateLimit-Limit:", "          $ref: '#/components/headers/RateLimitLimit'", "        X-RateLimit-Remaining:",
                    "          $ref: '#/components/headers/RateLimitRemaining'", "          description: Requests left in the window", "          schema: { type: integer }"]
        let ts = ["  retries: process.env.CI ? 2 : 0,", "  await page.waitForLoadState('networkidle');", "  expect(total).toBe('$45.00');"]
        var out = ""
        for file in stat.files {
            let pool = file.path.hasSuffix(".yaml") ? yaml : (file.path.hasSuffix(".ts") ? ts : go)
            out += "diff --git a/\(file.path) b/\(file.path)\n"
            switch file.status {
            case .added, .untracked: out += "new file mode 100644\n--- /dev/null\n+++ b/\(file.path)\n"
            case .deleted: out += "deleted file mode 100644\n--- a/\(file.path)\n+++ /dev/null\n"
            default: out += "--- a/\(file.path)\n+++ b/\(file.path)\n"
            }
            let context = file.status == .modified ? 2 : 0
            out += "@@ -12,\(file.deletions + context) +12,\(file.insertions + context) @@\n"
            if context > 0 { out += " \(pool[0])\n" }
            for index in 0 ..< file.deletions { out += "-\(pool[(index + 3) % pool.count])\n" }
            for index in 0 ..< file.insertions { out += "+\(pool[(index + 1) % pool.count])\n" }
            if context > 0 { out += " \(pool[pool.count - 1])\n" }
        }
        return out
    }

    private static let claudeHeadersDiff = #"""
diff --git a/internal/middleware/ratelimit.go b/internal/middleware/ratelimit.go
index 3f2a1c4..9b8e7d2 100644
--- a/internal/middleware/ratelimit.go
+++ b/internal/middleware/ratelimit.go
@@ -4,10 +4,12 @@ import (
 	"net/http"
 	"strconv"
 	"time"

 	"github.com/acme/api-gateway/internal/limiter"
 )

-// RateLimit rejects requests over the per-key budget.
+// RateLimit rejects requests over the per-key budget and tells every client where it
+// stands: X-RateLimit-Limit, X-RateLimit-Remaining and, when rejected, Retry-After.
 func RateLimit(l *limiter.Window, key func(*http.Request) string) func(http.Handler) http.Handler {
 	return func(next http.Handler) http.Handler {
 		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
@@ -18,14 +20,22 @@ func RateLimit(l *limiter.Window, key func(*http.Request) string) func(http.Handler) http.Handler {
 			k := key(r)
-			if !l.Allow(k) {
-				http.Error(w, "rate limited", http.StatusTooManyRequests)
+			decision := l.Take(k, time.Now())
+			writeLimitHeaders(w.Header(), decision)
+			if !decision.Allowed {
+				w.Header().Set("Retry-After", strconv.Itoa(int(decision.RetryAfter.Seconds()+0.5)))
+				writeProblem(w, http.StatusTooManyRequests, "rate_limited",
+					"Too many requests. Retry after the time in Retry-After.")
 				return
 			}
 			next.ServeHTTP(w, r)
 		})
 	}
 }
diff --git a/internal/middleware/headers.go b/internal/middleware/headers.go
new file mode 100644
index 0000000..4c1d2e9
--- /dev/null
+++ b/internal/middleware/headers.go
@@ -0,0 +1,18 @@
+package middleware
+
+import (
+	"net/http"
+	"strconv"
+
+	"github.com/acme/api-gateway/internal/limiter"
+)
+
+// writeLimitHeaders mirrors GitHub's and Stripe's names so existing clients just work.
+func writeLimitHeaders(h http.Header, d limiter.Decision) {
+	h.Set("X-RateLimit-Limit", strconv.Itoa(d.Limit))
+	h.Set("X-RateLimit-Remaining", strconv.Itoa(max(d.Remaining, 0)))
+	h.Set("X-RateLimit-Reset", strconv.FormatInt(d.ResetAt.Unix(), 10))
+}
+
+// Remaining never goes negative, even while a burst is being rejected.
+func max(a, b int) int { if a > b { return a }; return b }
diff --git a/internal/middleware/ratelimit_test.go b/internal/middleware/ratelimit_test.go
index 1a2b3c4..5d6e7f8 100644
--- a/internal/middleware/ratelimit_test.go
+++ b/internal/middleware/ratelimit_test.go
@@ -31,6 +31,28 @@ func TestRateLimitRejectsBurst(t *testing.T) {
 	if got := rec.Code; got != http.StatusTooManyRequests {
 		t.Fatalf("status = %d, want 429", got)
 	}
 }
+
+func TestRateLimitHeaders(t *testing.T) {
+	for _, tc := range []struct {
+		name      string
+		requests  int
+		remaining string
+		retry     bool
+	}{
+		{"first request", 1, "9", false},
+		{"last allowed", 10, "0", false},
+		{"over budget", 11, "0", true},
+	} {
+		t.Run(tc.name, func(t *testing.T) {
+			rec := hit(t, tc.requests)
+			if got := rec.Header().Get("X-RateLimit-Remaining"); got != tc.remaining {
+				t.Errorf("remaining = %q, want %q", got, tc.remaining)
+			}
+			if (rec.Header().Get("Retry-After") != "") != tc.retry {
+				t.Errorf("Retry-After present = %v, want %v", !tc.retry, tc.retry)
+			}
+		})
+	}
+}
diff --git a/docs/api/rate-limits.md b/docs/api/rate-limits.md
index 7e8f9a0..b1c2d3e 100644
--- a/docs/api/rate-limits.md
+++ b/docs/api/rate-limits.md
@@ -1,9 +1,17 @@
 # Rate limits

-Each API key may make 600 requests per minute. Requests over the limit get a 429.
+Each API key may make 600 requests per minute. Every response says where you stand:
+
+| Header | Meaning |
+| --- | --- |
+| `X-RateLimit-Limit` | Requests allowed in the current window |
+| `X-RateLimit-Remaining` | Requests left in the current window |
+| `X-RateLimit-Reset` | When the window resets (Unix seconds) |
+
+Requests over the limit get a `429` with `Retry-After` in seconds.

 ## Bursts

-Short bursts are allowed as long as the per-minute total stays under the limit.
+Short bursts are fine while the per-minute total stays under the limit; the window slides,
+so there is no cliff at the top of the minute.
\ No newline at end of file
"""#

    private static let flakyDiff = #"""
diff --git a/e2e/checkout.spec.ts b/e2e/checkout.spec.ts
index 2b4c6d8..8e0f1a3 100644
--- a/e2e/checkout.spec.ts
+++ b/e2e/checkout.spec.ts
@@ -12,11 +12,14 @@ test.describe("checkout", () => {
   test("applies the coupon before paying", async ({ page }) => {
     await page.goto("/cart");
     await page.getByRole("button", { name: "Apply coupon" }).click();
-    await page.waitForTimeout(500);
-    await expect(page.getByTestId("total")).toHaveText("$45.00");
+    // The total updates after the cart refetch, not after a fixed delay.
+    await page.waitForResponse((r) => r.url().endsWith("/api/cart") && r.ok());
+    await expect(page.getByTestId("total")).toHaveText("$45.00");
     await page.getByRole("button", { name: "Pay" }).click();
   });
 });
diff --git a/src/cart/useCart.ts b/src/cart/useCart.ts
index 5a6b7c8..9d0e1f2 100644
--- a/src/cart/useCart.ts
+++ b/src/cart/useCart.ts
@@ -40,7 +40,9 @@ export function useCart() {
   const applyCoupon = async (code: string) => {
-    setCoupon(code);
-    refetch();
+    setCoupon(code);
+    // Await the refetch so the total never shows the pre-coupon price.
+    await refetch();
   };
"""#

}
