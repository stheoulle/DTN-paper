"""Two-row snake topology for the DTN paper."""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from matplotlib.patches import FancyArrowPatch

# ── canvas ────────────────────────────────────────────────────────────────────
fig, ax = plt.subplots(figsize=(14 / 2.54, 11 / 2.54))   # 14 × 11 cm
ax.set_xlim(0, 14)
ax.set_ylim(0, 11)
ax.axis("off")

# Row y-centres
Y1 = 8.2   # top row
Y2 = 3.5   # bottom row
NODE_H = 2.0
HW_BPA = 1.1   # half-width for BPA/Charon nodes
HW_APP = 0.80  # half-width for App nodes

# ── colours ───────────────────────────────────────────────────────────────────
CAN_FILL = "#d4e6f6"
CAN_EDGE = "#2a6098"
BPA_FILL = "#ffffff"
BPA_EDGE = "#333333"
APP_FILL = "#f0f0f0"
APP_EDGE = "#888888"
LINK_COL = "#333333"

# ── node definitions ──────────────────────────────────────────────────────────
# Row 1  (left → right):  App1, Charon-A, alice, Unibo-BP
# Row 2  (right → left):  Hardy (below Unibo-BP), bob, Charon-B, App2
#
# X positions chosen so that:
#   • Unibo-BP and Hardy share the same x (vertical CAN link)
#   • bob is clearly to the RIGHT of alice (so no CAN-region overlap)

X_APP1  = 1.0    # App1  right = 1.80
X_CHA   = 3.4    # ChA   [2.30, 4.50]  gap from App1: 0.50
X_ALICE = 6.2    # Alice [5.10, 7.30]  gap from ChA:  0.60
X_UNIBO = 11.0   # Unibo [9.90, 12.1]  gap from Alice: 2.60
X_HARDY = 11.0   # Hardy [9.90, 12.1]  directly below Unibo
X_BOB   = 7.5    # Bob   [6.40, 8.60]  gap from Hardy: 1.30
X_CHB   = 3.8    # ChB   [2.70, 4.90]  gap from Bob:   1.50
X_APP2  = 1.0    # App2  right = 1.80  gap from ChB:   0.90

# ── styles ────────────────────────────────────────────────────────────────────
S_APP = dict(facecolor=APP_FILL, edgecolor=APP_EDGE, linestyle="--", lw=1.0)
S_BPA = dict(facecolor=BPA_FILL, edgecolor=BPA_EDGE, linestyle="-",  lw=1.2)
S_CAN = dict(facecolor=CAN_FILL, edgecolor=CAN_EDGE, linestyle="-",  lw=1.4)

def box(xc, yc, hw, style_kw):
    ax.add_patch(FancyBboxPatch(
        (xc - hw, yc - NODE_H / 2), 2 * hw, NODE_H,
        boxstyle="round,pad=0.08", zorder=2, **style_kw,
    ))

def label(xc, yc, lines, mono_idx=()):
    n = len(lines)
    for i, text in enumerate(lines):
        ty = yc + ((n - 1) / 2 - i) * 0.52
        is_title = (i == 0)
        is_mono  = i in mono_idx
        is_italic = "Charon" in text and is_title
        ax.text(
            xc, ty, text,
            ha="center", va="center",
            fontsize=7.0 if is_title else 5.6,
            fontweight="bold" if is_title else "normal",
            fontstyle="italic" if is_italic else "normal",
            fontfamily="monospace" if is_mono else "sans-serif",
            color="#111111", zorder=3,
        )

def bilink(x1, y1, x2, y2, lbl, lbl_side="above"):
    """Draw two arrows (forward + back) and a label outside the node boxes."""
    dx, dy = x2 - x1, y2 - y1
    length = (dx**2 + dy**2) ** 0.5 or 1e-9
    ox, oy = -dy / length * 0.10, dx / length * 0.10

    ax.add_patch(FancyArrowPatch(
        (x1 + ox, y1 + oy), (x2 + ox, y2 + oy),
        arrowstyle="-|>", mutation_scale=7,
        color=LINK_COL, lw=0.9, zorder=4,
    ))
    ax.add_patch(FancyArrowPatch(
        (x2 - ox, y2 - oy), (x1 - ox, y1 - oy),
        arrowstyle="-|>", mutation_scale=7,
        color=LINK_COL, lw=0.9, zorder=4,
    ))
    xm, ym = (x1 + x2) / 2, (y1 + y2) / 2
    # place labels *outside* node boxes: ym ± (NODE_H/2 + margin)
    if lbl_side == "above":
        ax.text(xm, ym + NODE_H / 2 + 0.22, lbl, ha="center", va="bottom",
                fontsize=5.6, color=LINK_COL, linespacing=1.3, zorder=5)
    elif lbl_side == "below":
        ax.text(xm, ym - NODE_H / 2 - 0.18, lbl, ha="center", va="top",
                fontsize=5.6, color=LINK_COL, linespacing=1.3, zorder=5)
    elif lbl_side == "right":
        ax.text(xm + 0.22, ym, lbl, ha="left", va="center",
                fontsize=5.6, color=LINK_COL, linespacing=1.3, zorder=5)

# ── Row 1 nodes ───────────────────────────────────────────────────────────────
box(X_APP1,  Y1, HW_APP, S_APP)
label(X_APP1, Y1, ["App1", "sender"])

box(X_CHA,   Y1, HW_BPA, S_BPA)
label(X_CHA,  Y1, ["Charon", "(alice)"])

box(X_ALICE, Y1, HW_BPA, S_CAN)
label(X_ALICE, Y1, ["uD3TN", "alice.dtn/", "A-SABR"], mono_idx=(1,))

box(X_UNIBO, Y1, HW_BPA, S_CAN)
label(X_UNIBO, Y1, ["Unibo-BP", "ipn:1.0", "CSP addr 1"], mono_idx=(1,))

# ── Row 2 nodes ───────────────────────────────────────────────────────────────
box(X_HARDY, Y2, HW_BPA, S_CAN)
label(X_HARDY, Y2, ["Hardy", "ipn:2.0", "A-SABR · CSP 2"], mono_idx=(1,))

box(X_BOB,   Y2, HW_BPA, S_CAN)
label(X_BOB,  Y2, ["uD3TN", "bob.dtn/", "A-SABR · CSP 3"], mono_idx=(1,))

box(X_CHB,   Y2, HW_BPA, S_BPA)
label(X_CHB,  Y2, ["Charon", "(bob)"])

box(X_APP2,  Y2, HW_APP, S_APP)
label(X_APP2, Y2, ["App2", "receiver"])

# ── CAN region label (brace-style annotation) ─────────────────────────────────
can_lx = X_BOB  - HW_BPA - 0.2
can_rx = X_HARDY + HW_BPA + 0.2
# pushed down so it clears the "below" link labels (which sit at Y2-NODE_H/2-0.18)
can_by = Y2 - NODE_H / 2 - 1.0
# horizontal bracket


# ── Row 1 horizontal links ────────────────────────────────────────────────────
bilink(X_APP1 + HW_APP,  Y1, X_CHA  - HW_BPA, Y1, "UDP/IP",        "above")
bilink(X_CHA  + HW_BPA,  Y1, X_ALICE - HW_BPA, Y1, "AAP2",          "above")
bilink(X_ALICE + HW_BPA, Y1, X_UNIBO - HW_BPA, Y1, "TCPCLv3\n100 kbps", "above")

# ── Vertical link (Unibo-BP → Hardy, CAN) ────────────────────────────────────
bilink(X_UNIBO, Y1 - NODE_H / 2, X_HARDY, Y2 + NODE_H / 2,
       "CSPCL\nCAN\n50 kbps", "right")

# ── Row 2 horizontal links (right → left in flow, drawn left→right visually) ──
bilink(X_BOB   + HW_BPA, Y2, X_HARDY - HW_BPA, Y2, "CSPCL/CAN\n50 kbps", "below")
bilink(X_CHB   + HW_BPA, Y2, X_BOB   - HW_BPA, Y2, "AAP2",               "below")
bilink(X_APP2  + HW_APP,  Y2, X_CHB   - HW_BPA, Y2, "UDP/IP",             "below")

# ── save ──────────────────────────────────────────────────────────────────────
out = "/home/prnm691/Documents/DTN-paper/topology.png"
plt.savefig(out, dpi=250, bbox_inches="tight", facecolor="white")
plt.close()
print(f"Saved: {out}")
