# Experimental ten-minute native-fatigue estimates

`RingFatigueEstimator` learns a personal proxy for the native `0x56` fatigue
byte and can emit a ten-minute timeline between native observations. This is
**experimental and unvalidated**. It is not the manufacturer's app stress
algorithm, a psychological stress probability, or a clinical scale.

The device supplies the target; the library fits coefficients from the caller's
own prior records. No pretrained health data, third-party model or fixed
physiological fusion weights are distributed. No ring settings are changed.

## Inputs and knowledge time

- `RingFatigueSample`: measurement/snapshot time, actual availability time and
  named features. Repeated conflicting snapshots are unavailable, not averaged.
- `RingNativeFatigueAnchor`: measurement time, actual availability time and the
  original fatigue byte. Same-time different values remain a conflict.
- `RingFatigueConfiguration`: explicit correction method, feature names and
  engineering policies. Defaults are not validated physiological thresholds.

Convert already received and appropriately age-filtered `RingStressFeatureSet`
with `RingFatigueSample(inputs:availableAt:)`. Its snapshot time is `inputs.at`;
this does not mean every modality was sensed simultaneously. Assemble only
histories actually received by that availability time. The adapter includes
unambiguous, age-qualified heart rate, activity steps, SDK-scaled temperature
and explicitly analyzed sleep-stage observed seconds. Sleep gaps are not awake;
stage counts are not a whole-night recovery score. Empty contexts and sleep
windows containing only missing or unknown stages contribute no features.
Known-stage observations may still be partial; their counts describe only the
observed intervals. Select the same explicit
sleep-window policy in training and inference. No automatic session is guessed.

The adapter excludes the **entire `0x56` context**: its current fatigue, HRV,
heart rate and update metadata must not reveal a hidden evaluation target.
Raw HRV remains available in the separate input API, but its statistic is
unknown. This first predictor does not pretend it is RMSSD. No clinical meaning
is assigned to temperature units or activity-bin timing. Optional context
features are research covariates, not established physiological corrections.

Caller-created numeric snapshots must apply the same feature meanings, source
age limits and window policies throughout. Missing selected features are not
imputed. Models with different features must be compared on the same targets,
with their coverage also reported.

## Fit once, predict with incoming anchors

```swift
let policy = RingFatigueConfiguration(
    correction: .learnedDecay, // explicit experimental choice; no default method
    featureNames: ["heartRateBPM"]
)
let estimator = try RingFatigueEstimator(
    samples: receivedSnapshots, anchors: receivedNativeAnchors,
    before: trainingCutoff, asOf: trainingKnowledgeTime,
    configuration: policy
)
let point = try estimator.estimate(
    samples: currentlyReceivedSnapshots,
    anchors: currentlyReceivedNativeAnchors,
    at: measurementTime, asOf: currentKnowledgeTime
)
```

Training uses anchors strictly before the cutoff, within the configured past
window, and available by training knowledge time. Anchor inputs must have been
available when that anchor arrived. Prediction rejects a model whose training
or knowledge time is later than the query. Late data can produce an explicitly
new result with a later `asOf`; the library never silently overwrites a stored
prediction. Persist both results if supporting revisions.

Allowed feature names: `heartRateBPM`, `activitySteps`, `temperatureSDKValue`,
`sleepDeepObservedSeconds`, `sleepLightObservedSeconds`,
`sleepRemObservedSeconds`, `sleepAwakeObservedSeconds`. The defaults select
heart rate only; enable additional materials after comparing their utility.
All other decoded materials remain in the separate multimodal input API.

The regression standardizes using training-only population means/scales and
fits ridge regression (unpenalized intercept). Features outside the training
range are unavailable. Constant features cannot silently permit extrapolation.
Insufficient training or calibration produces a reason, not zero fatigue.

## Four explicit comparison methods

Let `f` be the same fitted regression for both current inputs and anchor inputs,
`a` the latest available anchor, and `h` actual elapsed hours since that anchor.

| Method | Between native anchors |
| --- | --- |
| `carryForward` | `y(a)`; explicitly an estimated hold, never a fresh native reading |
| `unanchored` | `f(x(t))` |
| `fullResidual` | `f(x(t)) + y(a) - f(x(a))` |
| `learnedDecay` | `f(x(t)) + rho^h * (y(a) - f(x(a)))` |

All methods return an available, nonconflicting native value at its exact
measurement time as `native_observed`. A native value off the ten-minute grid
retains its original time; it is not relabelled as a new grid-time observation.

`learnedDecay` reconstructs each frozen daily regression using only observations
received by the start of that UTC day, resolving conflicts at that historical
knowledge cutoff. Each daily training window ends at its own cutoff, rather
than the final model's cutoff. A later revision
cannot remove a record from a model that was already frozen. Held-out current
inputs must have been available at the target's measurement time; the target
label itself may arrive later for evaluation.

For each target, calibration hides that target event and selects the latest
predecessor actually available at forecast time; conflicts or unusable anchor
inputs exclude that pair. Its input snapshot
is selected at the predecessor's receipt time, matching ordinary inference.
Both residuals use the same frozen daily regression. Pairs crossing a UTC-day
boundary are omitted so a model refit cannot be mistaken for signal decay.
This UTC blocking is an evaluation convention, not a sleep-night boundary.
Calibration uses real gaps within the maximum anchor age and a fixed numerical
grid `rho = 0, 0.01, ..., 1`, minimizing squared residual-pair prediction error.
Negative dependence is not represented. `rho == 0` means no residual correction
at any positive age; exact native observations still take precedence. Models
are not automatically retrained by new anchors; retrain explicitly and compute
both terms with the new model. No old-model residual state is reused.

Full residual correction need not improve predictions: a noisy or weakly
persistent anchor can worsen them. None of these methods is silently selected
as a validated production default. Compare against carry-forward and the
unanchored model before adopting a correction. Retention is a model parameter,
not a confidence probability.

## Output and ten-minute replay

Each `RingFatigueEstimate` includes value/status/reason, query and knowledge
times, anchor measurement/availability/age/value, input snapshot time, method,
model version, training cutoff/count and residual-pair/retention metadata.
`validationStatus` is always `experimental_unvalidated`.

The corrected calibration and input handling use model version
`native-fatigue-ridge-decay-v2`; retain this identifier with stored results to
distinguish them from v0.7.0's v1 estimates. This version change does not establish
predictive or clinical validity.

Statuses are `native_observed`, `estimated`, and `unavailable`. Missing inputs,
stale anchors, conflicts, inadequate training, missing calibration pairs,
extrapolation or predictions outside the native byte range return no numeric
value. Nonfinite regression intermediates fail with `invalid_training_fit`
instead of silently collapsing a feature into a constant prediction. Estimates
are not clipped into a reassuring score or stress category.

```swift
let timeline = try estimator.tenMinuteSeries(
    samples: snapshots, anchors: anchors, start: start, end: end
)
```

The interval is start-inclusive/end-exclusive, with one result every 600 seconds,
including explicit unavailable slots. Replay uses each slot as its knowledge
time. The window is bounded to 366 days. A clock too large to advance by the
requested interval is rejected instead of producing an endless replay.
For a historical-data replay without
receipt logs, disclose any assumed availability times; measurement time alone
does not prove that data was actually available then.

Offline CLI (no Bluetooth):

```sh
swift run smart-ring replay-native-fatigue request.json
```

Request fields: `samples`, `anchors`, `trainingBefore`, `trainedAsOf`, `start`,
`end`, `configuration`. Dates are ISO8601. Configuration JSON includes all seven
fields named by `RingFatigueConfiguration` (Swift initializer defaults are not
JSON decoding defaults). Keep real requests and results private health data.

The series API computes values when called. It neither schedules background
execution nor guarantees an iOS app can run every ten minutes. A consumer must
handle reconnects, delayed sync, original measurement times and backfill.

## What evaluation establishes

Hide the next native value and its entire current `0x56` event before inference,
including availability/missingness indicators. Freeze model policies using
past-only development data; evaluate later whole days with identical target
sets. Report coverage, MAE, maximum error, day-level variation and elapsed-time
bands for every method. Choose preprocessing/feature sets only on training data.

Predicting a later hourly native anchor does not prove accuracy at intervening
ten-minute points. Finer native recordings can provide additional held-out
checks, but a few points cannot validate general performance. Agreement with
native fatigue is not independent psychological-stress validation. The
[research references and input limitations](stress-analysis.md) motivate
personal baselines and activity/sleep context; they do not validate this new
regression or its correction formula on this device.
