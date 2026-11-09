# Drops request bodies and the client's API key from OPA's decision log, so
# neither prompts nor keys reach Loki; the log keeps who asked for which model
# and the verdict.
package system.log

import rego.v1

mask contains "/input/parsed_body"

mask contains "/input/truncated_body"

mask contains "/input/attributes/request/http/body"

mask contains "/input/attributes/request/http/raw_body"

mask contains "/input/attributes/request/http/headers/authorization"
