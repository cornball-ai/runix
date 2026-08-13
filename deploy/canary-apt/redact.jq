# Redaction for exported audit evidence. The raw sink holds sensitive broker state
# (receipt verifier hashes, bound fields); export ONLY non-secret projections:
#   - audit records: cid, actor, phase, operation, outcome, effect_issued
#   - broker_receipt records: cid + receipt STATE only (never the verifier)
#   - anything else: its record_type only
if (.phase != null) then
    {correlation_id, actor, phase, operation, outcome, effect_issued}
elif (.record_type == "broker_receipt") then
    {record_type, correlation_id, receipt_state: .state}
else
    {record_type: (.record_type // "unknown")}
end
