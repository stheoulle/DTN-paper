"""Draw the DTN validation topology as a PNG for inclusion in the paper."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
import matplotlib.patheffects as pe

# ── canvas ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(20 / 2.54, 7.5 / 2.54))   # 20 × 7.5 cm
ax.set_xlim(0, 22)
ax.set_ylim(0, 7.5)
ax.axis("off")

NODE_Y = 4.0
NODE_H = 2.2
Y_BOT  = NODE_Y - NODE_H / 2
Y_TOP  = NODE_Y + NODE_H / 2

# ── colours ───────────────────────────────────────────────────────────────────
CAN_FILL  = "#d4e6f6"
CAN_EDGE  = "#2a6098"
BPA_FILL  = "#ffffff"
BPA_EDGE  = "#333333"
APP_FILL  = "#f0f0f0"
APP_EDGE  = "#888888"
LINK_COL  = "#333333"

# ── node layout ───────────────────────────────────────────────────────────────
# (style, [line1, line2, line3], x_centre, half_width)
NODES = [
    ("app", ["App1", "sender"],                        1.15, 0.80),
    ("bpa", ["Charon", "(alice)"],                     3.30, 0.95),
    ("bpa", ["uD3TN", "alice.dtn/", "A-SABR"],       6.10, 1.15),
    ("can", ["Unibo-BP", "ipn:1.0", "CSP addr 1"],     9.30, 1.15),
    ("can", ["Hardy", "ipn:2.0", "A-SABR · CSP 2"], 12.50, 1.15),
    ("can", ["uD3TN", "bob.dtn/", "A-SABR · CSP 3"],15.70, 1.15),
    ("bpa", ["Charon", "(bob)"],                      18.70, 0.95),
    ("app", ["App2", "receiver"],                     20.85, 0.80),
]

LINK_LABELS = [
    "UDP/IP",
    "AAP2",
    "TCPCLv3\n100 kbps",
    "CSPCL/CAN\n50 kbps",
    "CSPCL/CAN\n50 kbps",
    "AAP2",
    "UDP/IP",
]

# ── CAN background ────────────────────────────────────────────────────────────
can_xL = NODES[3][2] - NODES[3][3] - 0.30
can_xR = NODES[5][2] + NODES[5][3] + 0.30
can_yB = Y_BOT - 0.40
can_yT = Y_TOP + 0.40


# ── nodes ─────────────────────────────────────────────────────────────────────
style_kw = {
    "app": dict(facecolor=APP_FILL, edgecolor=APP_EDGE, linestyle="--", lw=1.0),
    "bpa": dict(facecolor=BPA_FILL, edgecolor=BPA_EDGE, linestyle="-",  lw=1.2),
    "can": dict(facecolor=CAN_FILL, edgecolor=CAN_EDGE, linestyle="-",  lw=1.4),
}

for style, lines, xc, hw in NODES:
    ax.add_patch(FancyBboxPatch(
        (xc - hw, Y_BOT), 2 * hw, NODE_H,
        boxstyle="round,pad=0.08",
        zorder=2, **style_kw[style],
    ))
    n = len(lines)
    for i, text in enumerate(lines):
        ty     = NODE_Y + ((n - 1) / 2 - i) * 0.56
        title  = (i == 0)
        mono   = any(s in text for s in ("dtn/", "ipn:", "addr"))
        italic = ("Charon" in text and title)
        ax.text(
            xc, ty, text,
            ha="center", va="center",
            fontsize=7.2 if title else 5.8,
            fontweight="bold" if title else "normal",
            fontstyle="italic" if italic else "normal",
            fontfamily="monospace" if mono else "sans-serif",
            color="#111111",
            zorder=3,
        )

# ── links ─────────────────────────────────────────────────────────────────────
OFFSET = 0.10   # vertical offset for two-arrow pair

for k, label in enumerate(LINK_LABELS):
    _, _, xc_l, hw_l = NODES[k]
    _, _, xc_r, hw_r = NODES[k + 1]
    x1 = xc_l + hw_l
    x2 = xc_r - hw_r

    # Forward arrow (top)
    ax.add_patch(FancyArrowPatch(
        (x1, NODE_Y + OFFSET), (x2, NODE_Y + OFFSET),
        arrowstyle="-|>", mutation_scale=7,
        color=LINK_COL, lw=0.9, zorder=4,
    ))
    # Backward arrow (bottom)
    ax.add_patch(FancyArrowPatch(
        (x2, NODE_Y - OFFSET), (x1, NODE_Y - OFFSET),
        arrowstyle="-|>", mutation_scale=7,
        color=LINK_COL, lw=0.9, zorder=4,
    ))
    # Label
    ax.text(
        (x1 + x2) / 2, Y_TOP + 0.18, label,
        ha="center", va="bottom",
        fontsize=5.8, color=LINK_COL, linespacing=1.3,
        zorder=5,
    )

# ── save ──────────────────────────────────────────────────────────────────────
out = "/home/prnm691/Documents/DTN-paper/topology.png"
plt.savefig(out, dpi=250, bbox_inches="tight", facecolor="white")
plt.close()
print(f"Saved: {out}")
