
"""
    head(uuid::UUID) -> String

Extract the first part of a UUID string (before the first hyphen).
"""
function head(uuid::UUID)
    return split(string(uuid), "-")[1]
end
