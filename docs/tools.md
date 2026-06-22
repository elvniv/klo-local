# Tools

Tools are the boundary between model intent and real computer actions.

Core files:

- `agent2/tools.py`
- `agent2/agent.py`
- `agent2/prompts.py`
- `agent2/bridge.py`

## Adding A Tool

1. Add a schema entry to the tool inventory.
2. Implement execution in the dispatcher.
3. Return structured observations the model can verify.
4. Add tests or a smoke task.
5. Document permission or privacy impact.

## Safety Checklist

Mutating tools should:

- avoid destructive defaults
- ask for confirmation when the action is irreversible or costly
- redact obvious secret-shaped strings from logs/traces
- include enough result state for the next model turn to verify progress
- fail closed when permission or page state is ambiguous

## Browser Tools

Browser tools run through the Chrome extension bridge. Keep browser actions
grounded in visible page state: read/snapshot before click/fill, and return a
post-action observation.

## macOS Tools

macOS tools may need Accessibility, Screen Recording, or Apple Events. Prefer
explicit, observable actions over hidden automation.
