"""Единый стиль графиков: тонкие линии, светлая сетка, проверенная палитра."""
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

from .config import COLORS, FIGURES


def setup():
    plt.rcParams.update({
        "figure.dpi": 110, "savefig.dpi": 150, "figure.facecolor": COLORS["surface"],
        "axes.facecolor": COLORS["surface"], "axes.edgecolor": COLORS["grid"],
        "axes.labelcolor": COLORS["muted"], "axes.titlesize": 11, "axes.titleweight": "bold",
        "axes.titlecolor": COLORS["actual"], "axes.grid": True, "grid.color": COLORS["grid"],
        "grid.linewidth": 0.6, "axes.spines.top": False, "axes.spines.right": False,
        "xtick.color": COLORS["muted"], "ytick.color": COLORS["muted"], "font.size": 9,
        "lines.linewidth": 1.6, "legend.frameon": False, "font.family": "DejaVu Sans",
    })


def month_axis(ax, yearly=False):
    """Подписи оси дат без наложений: раз в полгода (или раз в год для мелких графиков)."""
    if yearly:
        ax.xaxis.set_major_locator(mdates.YearLocator())
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%Y"))
    else:
        ax.xaxis.set_major_locator(mdates.MonthLocator(bymonth=[1, 7]))
        ax.xaxis.set_major_formatter(mdates.DateFormatter("%m.%Y"))


def save(fig, name):
    FIGURES.mkdir(parents=True, exist_ok=True)
    fig.savefig(FIGURES / f"{name}.png", bbox_inches="tight", facecolor=COLORS["surface"])
