# Multimodal stress research inputs

`RingStressInputs` assembles measured inputs for independent physiological-load
research. It does **not** produce a validated stress score, probability or
low/medium/high classifier. It performs no device operations.

## Apple API

```swift
let inputs = try RingStressInputs.assemble(
    snapshot.histories.map(\.decoded), at: evaluationTime,
    timeZone: historicalTimeZone,
    maximumAge: 30 * 60, // application policy, not a validated threshold
    referenceWindow: priorReferenceWindow,
    sleepWindow: previousNightWindow,
    sleepMapping: verifiedDeviceProfile.sleepMapping
)
```

Omit both sleep arguments for an unknown profile or an unestablished session.
The caller supplies the historical time zone, age policy and analysis windows.
Both windows must end no later than evaluation; the reference is end-exclusive.
Pass histories from the same person, device and firmware profile. Decoded
histories contain no source identity for this API to enforce that separation.
Timezone changes and repeated daylight-saving wall times may require segmenting
the source history first. A timezone name alone cannot disambiguate every clock.

| Command | Material | Interpretation limit |
| --- | --- | --- |
| `0x55` | Scalar heart rate | A sample is not continuous coverage |
| `0x56` | `hrvRaw`, `nativeFatigueRaw`, BPM | HRV statistic/unit and fatigue algorithm unknown; not RMSSD or app stress |
| `0x52` | Steps and original ten bins | Bin duration/anchor unresolved; zero steps does not establish stillness |
| `0x62` | SDK-scaled/raw temperature and extension bytes | Physical unit and channel roles unresolved |
| `0x54` | Original fifteen BPM samples | Unknown spacing; cannot reconstruct beat intervals |
| `0x66` | SDK-labelled oxygen saturation | Context, not an established stress predictor |
| `0x5c` | Exercise records if available | Nonempty target-device history remains unverified |
| `0x53` | Explicitly mapped sleep timeline | Unknown/conflicting/missing coverage remains visible; not a sleep score |

For nonsleep categories, the latest timestamp at or before evaluation is
selected. Stale records remain with `ageSeconds` and `withinAgeLimit == false`;
missing commands are separate. Future records and fabricated zeros are never
substituted. Distinct payloads at the latest timestamp remain as multiple
`records` (`isConflicting` in Swift). The computed convenience flag is not a
separate JSON field. Sequence-counter changes alone do not create a conflict.

Original bytes preserve undecoded extensions. Retain opaque/unsupported
histories, such as observed `0x67` records, in the original capture; these are not
invented model inputs. Decoder issues are preserved. Because decoded records do
not establish radio completion, `transferCompletenessKnown` is false: keep
capture failures, completeness and receipt times separately. Measurement-time
assembly does not prove that data had arrived in an app at that historical time.
For arrival-time retrospective evaluation, the caller must first exclude records
received after the evaluation time.

Sleep samples must have completed by evaluation before they contribute. Their
completed intervals are then clipped to the requested sleep window, so a sample
crossing a past window's end contributes only its overlap. A five-minute sample
that is still in progress at evaluation contributes nothing.

## Descriptive heart-rate reference

An optional window produces `median-mad-v1`: select distinct, nonconflicting
positive `0x55` BPM values; compute their median and median absolute deviation;
return current-minus-median in BPM and, for positive dispersion, difference/MAD.
The current value must be unambiguous and inside the age limit. When it falls
inside the reference window, its timestamp is excluded from the reference so it
cannot influence its own difference. Without a usable current value, all
eligible reference samples remain and no current difference is produced. An absent
reference produces no reference; zero dispersion produces no normalized
difference, **not zero stress**. Sample/conflict counts are exposed. No minimum
clinical sample count, probability, clipping or category threshold is encoded.

The reference is not automatically resting, waking or sleeping HR. Select
appropriate windows/records using established sleep/activity evidence. This
descriptive method is not Neigel's full skew-normal mode-fitting algorithm and
not the manufacturer's formula. Other modalities remain separate components;
no unvalidated fusion weights are shipped.

## Offline CLI

```sh
swift run smart-ring analyze-stress-inputs request.json
```

`histories` contains `RingDecodedHistory` objects, for example from `decode-raw`:

```json
{
  "histories": [],
  "at": "2024-02-29T12:00:00Z",
  "timeZone": "UTC",
  "maximumAgeSeconds": 1800,
  "referenceWindow": {"start": "2024-02-28T12:00:00Z", "duration": 86400},
  "sleepWindow": {"start": "2024-02-28T22:00:00Z", "duration": 28800},
  "sleepProfile": "issin-0.7.5.0"
}
```

Dates are ISO8601; durations are seconds. Reference/sleep fields are optional.
This synthetic empty example starts no Bluetooth connection or measurement.
Keep real request/output files private: they contain health records.

## Research basis and evaluation

- [Neigel et al., 2025](https://www.frontiersin.org/journals/computer-science/articles/10.3389/fcomp.2025.1575404/full):
  individual baselines, sparse ring HR and sleep context; cohort/period analysis,
  not validation of ten-minute psychological-stress classification.
- [Presby et al., 2023](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0285332):
  time-of-day references and postexercise effects, using motionless HR and dense
  beat-derived RMSSD unavailable in the current ring history.
- [Van de Ven et al., 2024/2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC11775876/):
  posture and current/past activity matter; processed bins cannot reproduce its
  raw-accelerometer correction method.
- [Yang, Yu and Sano, CHIL 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12975034/),
  [author implementation](https://github.com/comp-well-org/clip-stress-detection):
  multimodal wearable/context research with hourly inputs and daily targets,
  not a ten-minute ring-ready model. No author code or trained weights are included.

Compare additional modalities with a heart-only reference on the same held-out
observations. Fit baselines, missing-data transforms and coefficients on prior
training data only; separate whole days/nights. Report freshness, missingness,
activity/sleep strata, source/firmware and sampling assumptions. App-score
agreement evaluates imitation, not psychological validity. A validated stress
estimator needs independent time-aligned labels and out-of-fitting evaluation.
Input assembly does not itself establish improved prediction accuracy.


## Optional experimental predictor

The separate [native-fatigue estimation API](native-fatigue-estimation.md) can
learn a personal proxy and explicitly compare correction methods between native
anchors. This input assembler remains a score-free record/context API. The
predictor is not a validated psychological-stress model.
