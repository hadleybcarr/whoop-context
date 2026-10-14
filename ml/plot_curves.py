"""Plot training vs validation loss and accuracy for the stress and mood models.

The models are ridge regressions, which are solved in one step rather than trained over epochs,
so the curves use the two knobs that do exist:
  - learning curves: error as the model sees more events (x = number of training events)
  - regularization curves: error as ridge alpha goes from loose to strict

Loss is mean absolute error. Accuracy is the share of events predicted within ±0.5 of the
true label (stress is 0-3, feeling is -2..2). Validation folds are grouped by day, same as train.py.

Usage:
  python ml/plot_curves.py                   # uses ml/data/events_labeled.csv, else demo data
  python ml/plot_curves.py --data path/to.csv
Writes ml/plots/learning_curves.png and ml/plots/alpha_curves.png.
"""

import argparse
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from sklearn.metrics import make_scorer
from sklearn.model_selection import GroupKFold, learning_curve, validation_curve

from train import MIN_ROWS, ROOT, add_features, default_data_path, make_model

TOLERANCE = 0.5
SCORING = {
    "loss": "neg_mean_absolute_error",
    "acc": make_scorer(lambda y, p: float(np.mean(np.abs(y - p) <= TOLERANCE))),
}
TRAIN_COLOR, VAL_COLOR = "#2a78d6", "#e8743b"


def targets(df: pd.DataFrame):
    yield "Stress (0–3)", df[(df["active"] == 0) & df["stress"].notna()], "stress"
    rated = df[df["feeling"].notna()]
    if len(rated) >= MIN_ROWS:
        yield "Feeling (−2…+2)", rated, "feeling"


def cv_for(df: pd.DataFrame) -> GroupKFold:
    return GroupKFold(n_splits=min(5, df["date"].nunique()))


def band(ax, x, scores, color, label):
    mean, std = scores.mean(axis=1), scores.std(axis=1)
    ax.plot(x, mean, "o-", color=color, label=label, markersize=4)
    ax.fill_between(x, mean - std, mean + std, color=color, alpha=0.15, linewidth=0)


def plot_grid(rows, x_label, log_x, title, out_path):
    fig, axes = plt.subplots(len(rows), 2, figsize=(11, 4 * len(rows)), squeeze=False)
    for (name, x, res, baseline), (ax_loss, ax_acc) in zip(rows, axes):
        band(ax_loss, x, -res["train_loss"], TRAIN_COLOR, "Training")
        band(ax_loss, x, -res["val_loss"], VAL_COLOR, "Validation")
        ax_loss.axhline(baseline, color="gray", linestyle="--", linewidth=1, label="Guessing the average")
        ax_loss.set_title(f"{name} — loss (MAE, lower is better)")
        ax_loss.set_ylabel("Mean absolute error")

        band(ax_acc, x, res["train_acc"] * 100, TRAIN_COLOR, "Training")
        band(ax_acc, x, res["val_acc"] * 100, VAL_COLOR, "Validation")
        ax_acc.set_title(f"{name} — accuracy (within ±{TOLERANCE})")
        ax_acc.set_ylabel("% of events")
        ax_acc.set_ylim(0, 105)

        for ax in (ax_loss, ax_acc):
            ax.set_xlabel(x_label)
            if log_x:
                ax.set_xscale("log")
            ax.grid(alpha=0.3)
            ax.spines[["top", "right"]].set_visible(False)
            ax.legend(frameon=False)
    fig.suptitle(title, fontsize=14, fontweight="bold")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, default=None)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "ml" / "plots")
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    data_path = args.data or default_data_path()
    df = add_features(pd.read_csv(data_path))
    print(f"Loaded {len(df)} events from {data_path.name}")

    learning_rows, alpha_rows = [], []
    alphas = np.logspace(-2, 3, 12)
    for name, sub, target in targets(df):
        y = sub[target].to_numpy(dtype=float)
        baseline = float(np.mean(np.abs(y - y.mean())))

        # learning_curve and validation_curve take one metric at a time.
        res = {}
        for key, scorer in SCORING.items():
            sizes, tr, va = learning_curve(
                make_model(1.0), sub, y, train_sizes=np.linspace(0.15, 1.0, 8), shuffle=True,
                random_state=0, groups=sub["date"], cv=cv_for(sub), scoring=scorer,
            )
            res[f"train_{key}"], res[f"val_{key}"] = tr, va
        learning_rows.append((name, sizes, res, baseline))

        res = {}
        for key, scorer in SCORING.items():
            tr, va = validation_curve(
                make_model(1.0), sub, y, param_name="ridge__alpha", param_range=alphas,
                groups=sub["date"], cv=cv_for(sub), scoring=scorer,
            )
            res[f"train_{key}"], res[f"val_{key}"] = tr, va
        alpha_rows.append((name, alphas, res, baseline))

        print(f"  {target:8s} n={len(sub)}  final val MAE {-learning_rows[-1][2]['val_loss'][-1].mean():.2f}"
              f"  val acc {learning_rows[-1][2]['val_acc'][-1].mean():.0%}")

    plot_grid(learning_rows, "Training events", False,
              "Learning curves (cross-validated by day)", args.out_dir / "learning_curves.png")
    plot_grid(alpha_rows, "Ridge alpha (regularization strength)", True,
              "Regularization curves (cross-validated by day)", args.out_dir / "alpha_curves.png")
    print(f"Wrote {args.out_dir.relative_to(ROOT)}/learning_curves.png and alpha_curves.png")


if __name__ == "__main__":
    main()
