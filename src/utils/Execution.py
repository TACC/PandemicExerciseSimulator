"""Execution policy; these settings are deliberately outside scenario identity."""
import os


def parse_execution(value):
    if value is None:
        value = {}
    if not isinstance(value, dict):
        raise ValueError('execution must be an object')
    unknown = set(value) - {'mode', 'workers'}
    if unknown:
        raise ValueError(f'Unknown execution settings: {sorted(unknown)}')
    mode = value.get('mode', 'serial')
    workers = value.get('workers', 'auto')
    if mode not in ('serial', 'parallel'):
        raise ValueError('execution.mode must be serial or parallel')
    if workers != 'auto' and (type(workers) is not int or workers < 1):
        raise ValueError('execution.workers must be auto or a positive integer')
    return {'mode': mode, 'workers': workers}


def choose_workers(execution, realizations):
    """Respect command budgets, not the aggregate CPUs of a multi-node job.

    PyLauncher users must pass SIMULATOR_CPUS_PER_TASK matching its cores= value.
    Without a command budget, Slurm jobs conservatively run one worker.
    """
    if execution['mode'] == 'serial':
        return 1
    cpus = os.cpu_count() or 1
    if hasattr(os, 'sched_getaffinity'):
        cpus = min(cpus, len(os.sched_getaffinity(0)))
    budget = os.environ.get('SIMULATOR_CPUS_PER_TASK') or os.environ.get('SLURM_CPUS_PER_TASK')
    if budget is not None:
        try:
            budget = int(budget)
        except ValueError as exc:
            raise ValueError('Per-command CPU budget must be a positive integer') from exc
        if budget < 1:
            raise ValueError('Per-command CPU budget must be a positive integer')
        cpus = min(cpus, budget)
    elif 'SLURM_JOB_ID' in os.environ:
        cpus = 1
    else:
        cpus = max(1, cpus - 1)  # Leave local interactive headroom.
    requested = execution['workers']
    return min(realizations, cpus, 4 if requested == 'auto' else requested)
