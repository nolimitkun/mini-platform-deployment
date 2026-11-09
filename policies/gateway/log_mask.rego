# Drops request bodies from OPA's decision log, so prompts never reach Loki;
# the log keeps who asked for which model and the verdict.
package system.log

import rego.v1

mask contains "/input/parsed_body"

mask contains "/input/truncated_body"

mask contains "/input/attributes/request/http/body"

mask contains "/input/attributes/request/http/raw_body"
