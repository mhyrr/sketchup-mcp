# SketchUp MCP Examples

This directory contains example scripts demonstrating how to use the SketchUp MCP (Model Context Protocol) integration.

## Ruby Code Evaluation

The SketchUp MCP now supports evaluating arbitrary Ruby code directly in SketchUp. This powerful feature allows you to create complex models and perform advanced operations that might not be directly exposed through the MCP API.

### Requirements

- SketchUp with the MCP extension installed (version 1.6.0 or later)
- Python 3.10 or later
- sketchup-mcp Python package (version 0.1.17 or later)

### Examples

#### Simple Ruby Eval Example

The `simple_ruby_eval.py` script demonstrates basic usage of the `eval_ruby` feature with several simple examples:

- Creating a line
- Creating a cube
- Getting model information

To run the example:

```bash
python examples/simple_ruby_eval.py
```

#### Arts and Crafts Cabinet Example

The `arts_and_crafts_cabinet.py` script demonstrates a more complex example, creating a detailed arts and crafts style cabinet with working doors using Ruby code.

To run the example:

```bash
python examples/arts_and_crafts_cabinet.py
```

### Using the eval_ruby Feature in Your Own Code

To use the `eval_ruby` feature in your own code:

```python
from mcp.client import Client
import json

# Connect to the SketchUp MCP server
client = Client("sketchup")

# Define your Ruby code
ruby_code = """
    model = Sketchup.active_model
    entities = model.active_entities
    line = entities.add_line([0,0,0], [100,100,100])
    line.entityID
"""

# Evaluate the Ruby code
response = client.eval_ruby(code=ruby_code)

# Parse the response
result = json.loads(response)
if result.get("success"):
    print(f"Success! Result: {result.get('result')}")
else:
    print(f"Error: {result.get('error')}")
```

### Tips for Using eval_ruby

1. **Return Values**: The last expression in your Ruby code will be returned as the result. Make sure to return something meaningful, like an entity ID or a JSON string.

2. **Error Handling**: Ruby errors will be caught and returned in the response. Check the `success` field to determine if the code executed successfully.

3. **Model Operations**: For operations that modify the model, consider wrapping them in `model.start_operation` and `model.commit_operation` to make them undoable.

4. **Performance**: For complex operations, it's more efficient to send a single large Ruby script than many small ones.

5. **Security**: Be careful when evaluating user-provided Ruby code, as it has full access to the SketchUp API. 