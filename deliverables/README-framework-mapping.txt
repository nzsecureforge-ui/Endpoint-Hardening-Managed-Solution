POLICY -> SECURITY FRAMEWORK MAPPING
Generated 2026-09-09 from CIS_Compliance_Baseline_v2.xlsx ("Compliance Baseline" sheet)
cross-referenced against the 222 policy files in source-pack/.

Nothing in these files is invented. Every NIST / ISO value is copied verbatim from the
workbook. Where a policy has no workbook row, the framework columns are left EMPTY and the
row is marked UNMAPPED — no control was inferred, guessed, or filled in.

--------------------------------------------------------------------------------------
1. policy-framework-map.csv        222 rows — one per policy file. The main deliverable.
--------------------------------------------------------------------------------------
   198 mapped, 24 unmapped.

   match_method tells you HOW each row was matched, so any mapping can be spot-checked:
     exact       164  workbook policy name == filename, character for character
     punctuation  14  matched after normalising punctuation / .mobileconfig / export
                      timestamps / a mangled curly apostrophe (#U2019)
     whitespace   10  matched after collapsing double spaces and trimming
     prefix       10  matched after normalising a differing rule-name prefix, e.g. workbook
                      "ASR - BLOCK - Block X" vs file "CISv4 - WIN - L1 - ASR: Block X"
     unmapped     24  the workbook row for this policy is numbered but entirely blank

   No policy matched two workbook rows, and no workbook row was used twice.
   No fuzzy/similarity matching was used in the final output.

   The 24 unmapped policies are NOT missing from the workbook by accident of naming — the
   workbook genuinely contains no data for them. Rows 11, 21, 24, 25, 33, 38, 43, 49, 52,
   55, 60, 75, 78, 89, 91, 92, 97, 99, 103, 110, 117, 183, 189 and 196 carry a policy
   number and nothing else. To close this gap the workbook has to be filled in; it cannot
   be derived from anything shipped in this pack.

--------------------------------------------------------------------------------------
2. policy-control-pairs.csv        575 rows — long format, one row per policy x control.
--------------------------------------------------------------------------------------
   Use this for pivots: filter framework = "NIST SP 800-53 Rev 5", group by control, and
   you get the policies evidencing that control. Policies citing three controls appear
   three times, which is why this is longer than 222.

   Two placeholder values appear in the control column and both mean "no control", not
   "control zero":
     (no workbook row)   this policy has no workbook row at all (the 24 above)
     (none recorded)     the workbook row exists but records a literal "-" instead of a
                         control. 15 rows do this, all Edge CIS items, mostly browser-UX
                         controls with no clean framework analogue.

--------------------------------------------------------------------------------------
3. control-coverage.csv            47 rows — control -> how many policies map to it.
--------------------------------------------------------------------------------------
   31 distinct NIST SP 800-53 Rev 5 controls, 16 distinct ISO/IEC 27001:2022 Annex A
   clauses. Counts exclude the two placeholders above.

--------------------------------------------------------------------------------------
KNOWN DISCREPANCY
--------------------------------------------------------------------------------------
"Configure the list of types that are excluded from synchronization" is recorded as L2 in
the workbook; the policy file is named CISv3 - EDGE - L1 - ... One of the two is wrong.
The CSV reports the workbook's value (L2) since the workbook is the mapping source.
