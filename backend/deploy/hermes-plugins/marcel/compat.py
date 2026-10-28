"""Bridge the installed Hermes skills API/catalog signature mismatch, without editing Hermes."""

import functools
import inspect


def skills_api_compat(module=None) -> bool:
    if module is None:
        from tools import skills_tool as module
    original = module.find_all_skills
    parameters = inspect.signature(original).parameters
    if ("include_editorial" in parameters
            or any(p.kind == inspect.Parameter.VAR_KEYWORD for p in parameters.values())):
        return False

    @functools.wraps(original)
    def compatible(*args, include_editorial=False, **kwargs):
        # Older catalogs have no editorial tier. Preserve their filtering and disabled state;
        # only consume the newer API's optional listing keyword.
        return original(*args, **kwargs)

    # Expose the accepted keyword so repeated profile registrations remain idempotent.
    compatible.__signature__ = inspect.Signature([
        *parameters.values(), inspect.Parameter("include_editorial", inspect.Parameter.KEYWORD_ONLY, default=False)])
    module.find_all_skills = compatible
    return True
