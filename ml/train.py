"""Learn which calendar events drive stress and which drive happiness.

Labels come from the page's export (events_labeled.csv):
  - stress  (0-3): physiological, from heart rate during the event vs your daily baseline.
                   Physical-activity events are excluded, since their HR rise is effort.
  - feeling (-2..2): self-reported "How did it feel?" rating. Heart rate measures arousal,
                   not whether it was pleasant, so happiness needs this label.

Features describe the event only (title words, time of day, weekday, duration, attendees,
recurring), so the models answer: "given what's on my calendar, how will it affect me?"

Usage:
  python ml/train.py                         # uses ml/data/events_labeled.csv, else demo data
  python ml/train.py --data path/to.csv
Writes web/insights.json (and ios/FinalThread/Resources/insights.json), which the INSIGHTS tab reads.
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import Ridge
from sklearn.metrics import mean_absolute_error, r2_score
from sklearn.model_selection import GroupKFold, cross_val_predict
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "ml" / "data"
MIN_ROWS = 15


def default_data_path() -> Path:
    real = DATA_DIR / "events_labeled.csv"
    return real if real.exists() else DATA_DIR / "demo_events.csv"


def add_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["title_norm"] = df["title"].str.lower().str.replace(r"[^a-z0-9 ]+", " ", regex=True)
    df["hour_sin"] = np.sin(2 * np.pi * df["start_hour"] / 24)
    df["hour_cos"] = np.cos(2 * np.pi * df["start_hour"] / 24)
    df["log_duration"] = np.log1p(df["duration_min"])
    df["log_attendees"] = np.log1p(df["attendees"])
    return df


def make_model(alpha: float) -> Pipeline:
    features = ColumnTransformer([
        ("title", TfidfVectorizer(ngram_range=(1, 2), sublinear_tf=True, stop_words="english"), "title_norm"),
        ("num", StandardScaler(), ["hour_sin", "hour_cos", "log_duration", "log_attendees", "recurring"]),
        ("weekday", OneHotEncoder(handle_unknown="ignore"), ["weekday"]),
    ])
    return Pipeline([("features", features), ("ridge", Ridge(alpha=alpha))])


def fit_and_evaluate(df: pd.DataFrame, target: str, alpha: float = 1.0):
    """Cross-validate grouped by date (no peeking at the same day), then fit on everything."""
    model = make_model(alpha)
    y = df[target].to_numpy(dtype=float)
    groups = df["date"]
    n_splits = min(5, groups.nunique())
    pred = cross_val_predict(model, df, y, groups=groups, cv=GroupKFold(n_splits=n_splits))
    metrics = {
        "mae": float(mean_absolute_error(y, pred)),
        "baseline_mae": float(mean_absolute_error(y, np.full_like(y, y.mean()))),
        "r2": float(r2_score(y, pred)),
        "n": int(len(df)),
    }
    model.fit(df, y)
    return model, metrics


def title_words(model: Pipeline, k: int = 6):
    """Title phrases with the strongest positive and negative weights, without repeating words."""
    features = model.named_steps["features"]
    vocab = features.named_transformers_["title"].get_feature_names_out()
    coefs = model.named_steps["ridge"].coef_[: len(vocab)]
    order = np.argsort(coefs)
    up = [(vocab[i], coefs[i]) for i in order[::-1][:20] if coefs[i] > 0]
    down = [(vocab[i], -coefs[i]) for i in order[:20] if coefs[i] < 0]
    return dedupe_phrases(up, k), dedupe_phrases(down, k)


def dedupe_phrases(weighted: list[tuple[str, float]], k: int) -> list[str]:
    """Turn TF-IDF terms into tags that never repeat a word.

    Overlapping two-word terms are chained into one phrase ("investor pitch" + "pitch practice"
    → "investor pitch practice"), single words already inside a phrase are dropped, and any
    remaining overlap keeps the higher-weighted phrase.
    """
    phrases: list[list] = []  # [tokens, weight]
    for term, w in (t for t in weighted if " " in t[0]):
        a, b = term.split()
        for p in phrases:
            toks = p[0]
            if a in toks and b in toks:
                break
            if toks[-1] == a and b not in toks:
                toks.append(b)
                break
            if toks[0] == b and a not in toks:
                toks.insert(0, a)
                break
        else:
            phrases.append([[a, b], w])
            continue
        p[1] = max(p[1], w)
    for term, w in (t for t in weighted if " " not in t[0]):
        for p in phrases:
            if term in p[0]:
                p[1] = max(p[1], w)
                break
        else:
            phrases.append([[term], w])

    # Weak terms make misleading tags; keep those within reach of the strongest.
    top = max((p[1] for p in phrases), default=0)
    out, used = [], set()
    for toks, w in sorted(phrases, key=lambda p: -p[1]):
        if used & set(toks) or w < 0.3 * top:
            continue
        out.append(" ".join(toks))
        used |= set(toks)
    return out[:k]


def build_insights(df: pd.DataFrame, source: str, days: pd.DataFrame | None = None) -> dict:
    """Fit both event models (and the next-morning recovery model when `days` is given) → insights dict."""
    df = add_features(df)
    stress_df = df[(df["active"] == 0) & df["stress"].notna()]
    rated_df = df[df["feeling"].notna()]
    if len(stress_df) < MIN_ROWS:
        raise ValueError(f"Need at least {MIN_ROWS} non-activity events with heart rate; have {len(stress_df)}.")

    stress_model, stress_metrics = fit_and_evaluate(stress_df, "stress")
    feeling_model, feeling_metrics = (None, None)
    if len(rated_df) >= MIN_ROWS:
        feeling_model, feeling_metrics = fit_and_evaluate(rated_df, "feeling")

    # Per-event-title summary from the fitted models.
    df["pred_stress"] = stress_model.predict(df).clip(0, 3)
    if feeling_model:
        df["pred_feeling"] = feeling_model.predict(df).clip(-2, 2)
    events = []
    for title, g in df.groupby("title"):
        active = bool(g["active"].iloc[0])
        events.append({
            "title": title,
            "n": int(len(g)),
            "stress": None if active else round(float(g["pred_stress"].mean()), 2),
            "observed_stress": None if active else round(float(g["stress"].mean()), 2),
            "feeling": round(float(g["pred_feeling"].mean()), 2) if feeling_model else None,
            "observed_feeling": round(float(g["feeling"].mean()), 2) if g["feeling"].notna().any() else None,
            "active": active,
        })

    stress_up, stress_down = title_words(stress_model)
    joy_up, joy_down = title_words(feeling_model) if feeling_model else ([], [])

    insights = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source": source,
        "n_events": int(len(df)),
        "n_rated": int(len(rated_df)),
        "models": {"stress": stress_metrics, "feeling": feeling_metrics},
        "events": sorted(events, key=lambda e: -(e["stress"] or 0)),
        "words": {"stress_up": stress_up, "stress_down": stress_down, "joy_up": joy_up, "joy_down": joy_down},
    }
    if days is not None:
        insights["recovery"] = build_recovery_insights(days)
    return insights


# ---- Next-morning recovery (works from WHOOP's daily API data alone) ----

MIN_DAYS = 10


def build_recovery_insights(days: pd.DataFrame) -> dict | None:
    """Ridge on one row per day: that day's calendar → the next morning's WHOOP recovery score.

    Columns: date, weekday, titles (space-joined event titles), n_events, busy_min, attendees,
    first_hour, last_hour, strain, next_recovery.
    """
    days = days[days["next_recovery"].notna()].copy()
    if len(days) < MIN_DAYS:
        return {"n": int(len(days)), "needed": MIN_DAYS}
    days["titles_norm"] = days["titles"].fillna("").str.lower().str.replace(r"[^a-z0-9 ]+", " ", regex=True)
    num = ["n_events", "busy_min", "attendees", "first_hour", "last_hour", "strain"]
    days[num] = days[num].astype(float).fillna(days[num].astype(float).median()).fillna(0)
    features = ColumnTransformer([
        ("title", TfidfVectorizer(sublinear_tf=True, stop_words="english", min_df=2), "titles_norm"),
        ("num", StandardScaler(), num),
    ])
    model = Pipeline([("features", features), ("ridge", Ridge(alpha=3.0))])
    y = days["next_recovery"].to_numpy(dtype=float)
    pred = cross_val_predict(model, days, y, cv=min(5, len(days)))
    model.fit(days, y)

    numeric = dict(zip(num, model.named_steps["ridge"].coef_[-len(num):]))
    raises, lowers = title_words(model)  # positive weight = higher recovery
    return {
        "n": int(len(days)),
        "mae": float(mean_absolute_error(y, pred)),
        "baseline_mae": float(mean_absolute_error(y, np.full_like(y, y.mean()))),
        "r2": float(r2_score(y, pred)),
        "mean_recovery": float(y.mean()),
        # Recovery points per standard deviation of each daily feature.
        "effects": {k: round(float(v), 2) for k, v in numeric.items()},
        "words": {"raises": raises, "lowers": lowers},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--data", type=Path, default=None)
    parser.add_argument("--out", type=Path, default=ROOT / "web" / "insights.json")
    args = parser.parse_args()

    data_path = args.data or default_data_path()
    df = pd.read_csv(data_path)
    print(f"Loaded {len(df)} events from {data_path.relative_to(ROOT) if data_path.is_relative_to(ROOT) else data_path}")
    try:
        insights = build_insights(df, data_path.name)
    except ValueError as err:
        raise SystemExit(str(err))
    if insights["models"]["feeling"] is None:
        print(f"Only {insights['n_rated']} rated events; rate at least {MIN_ROWS} to train the mood model.")

    args.out.write_text(json.dumps(insights, indent=2))
    # The iOS app bundles its own copy.
    ios_copy = ROOT / "ios" / "FinalThread" / "Resources" / "insights.json"
    if ios_copy.parent.exists():
        ios_copy.write_text(json.dumps(insights, indent=2))

    def report(name, m):
        print(f"  {name:8s} MAE {m['mae']:.2f} (guessing the average: {m['baseline_mae']:.2f})  R² {m['r2']:.2f}  n={m['n']}")

    print("\nCross-validated by day:")
    report("stress", insights["models"]["stress"])
    if insights["models"]["feeling"]:
        report("feeling", insights["models"]["feeling"])
    events, words = insights["events"], insights["words"]
    print("\nMost draining:", ", ".join(e["title"] for e in events[:3] if e["stress"] is not None))
    calm = sorted((e for e in events if e["stress"] is not None), key=lambda e: e["stress"])[:3]
    print("Calmest:      ", ", ".join(e["title"] for e in calm))
    print(f"Stress words: {', '.join(words['stress_up'])}")
    print(f"Calm words:   {', '.join(words['stress_down'])}")
    print(f"\nWrote {args.out.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
