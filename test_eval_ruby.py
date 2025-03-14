import json
from dataclasses import dataclass

@dataclass
class MockContext:
    request_id: int = 1

# Import the function we want to test
from sketchup_mcp.server import eval_ruby

# Test with a simple Ruby script
test_code = '''
model = Sketchup.active_model
entities = model.active_entities
line = entities.add_line([0,0,0], [100,100,100])
puts "Created line with ID: #{line.entityID}"
line.entityID
'''

# Call the function
result = eval_ruby(MockContext(), test_code)
print(f"Result: {result}")

# Parse the result
parsed = json.loads(result)
print(f"Parsed: {json.dumps(parsed, indent=2)}") 