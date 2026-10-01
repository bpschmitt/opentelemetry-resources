package live_check_advice

import rego.v1

# Escalate undocumented enum values from "information" to "violation".
# Weaver's built-in advisor only reports them at information level, but for
# this registry a value outside the enum (e.g. order.currency = "jpy") is a bug.
# Scoped to order.* so open upstream enums (e.g. error.type) are left alone.
deny contains make_advice("invalid_enum_value", "violation", value, message) if {
	input.sample.attribute
	startswith(input.sample.attribute.name, "order.")
	input.registry_attribute.type.members
	value := input.sample.attribute.value
	allowed := {m.value | some m in input.registry_attribute.type.members}
	not value in allowed
	message := sprintf(
		"Attribute '%s' has value '%v', which is not one of %v.",
		[input.sample.attribute.name, value, sort(allowed)],
	)
}

# Span names must be one of the registry's span definitions.
deny contains make_advice("unknown_span_name", "violation", name, message) if {
	input.sample.span
	name := input.sample.span.name
	not name in data.orders.span_names
	message := sprintf("Span name '%s' is not defined in the registry.", [name])
}

make_advice(advice_type, advice_level, value, message) := {
	"type": "advice",
	"advice_type": advice_type,
	"advice_level": advice_level,
	"advice_context": {"value": value},
	"message": message,
}
