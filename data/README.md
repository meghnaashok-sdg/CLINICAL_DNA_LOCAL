# Source data (NOT committed)

Put Manish's CSV extracts here. They are git-ignored (large + sensitive).

Required files (the 4 pipeline sources):
- `int_hills_us_clinic_dna_scenario_analysis_joined.csv`   (the sales spine — ~900k rows)
- `con_hills_us_clinic_dna_executive_summary_2024_to_date.csv`
- `int_hills_us_clinic_dna_action_summary.csv`
- `int_hills_us_clinic_dna_recommendation_setup.csv`

Data range needed: ~24 months (the models use a 12-month rolling window and a
24-months-ago baseline). Current extract covers 2024-09 → 2026-08.
