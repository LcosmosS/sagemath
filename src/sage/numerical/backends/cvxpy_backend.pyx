# sage.doctest: optional - cvxpy
r"""
CVXPY Backend

AUTHORS:

- Nathann Cohen (2010-10):   generic_backend template
- Matthias Koeppe (2022-03): this backend
- Zhongling Xu (2023):       refactor through :class:`MatrixBackend`

"""
# ****************************************************************************
#       Copyright (C) 2010 Nathann Cohen <nathann.cohen@gmail.com>
#                     2022 Matthias Koeppe <mkoeppe@math.ucdavis.edu>
#                     2023 Zhongling Xu
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#                  https://www.gnu.org/licenses/
# ****************************************************************************

from copy import copy
import cvxpy
from cvxpy.atoms.affine.add_expr import AddExpression
from cvxpy.expressions.constants import Constant
from cvxpy.constraints.zero import Equality
from sage.numerical.mip import MIPSolverException
from sage.rings.real_double import RDF

cdef class CVXPYBackend(MatrixBackend):
    """
    MIP Backend that delegates to CVXPY.

    CVXPY interfaces to various solvers, see
    https://www.cvxpy.org/install/index.html#install and
    https://www.cvxpy.org/tutorial/advanced/index.html#choosing-a-solver

    EXAMPLES::

        sage: import cvxpy
        sage: cvxpy.installed_solvers()                                                # random

    Using the default solver determined by CVXPY::

        sage: p = MixedIntegerLinearProgram(solver="CVXPY"); p.solve()
        0.0

    Using a specific solver::

        sage: p = MixedIntegerLinearProgram(solver="CVXPY/OSQP"); p.solve()
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/ECOS"); p.solve()
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/SCS"); p.solve()
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/SciPy/HiGHS"); p.solve()
        0.0

    Open-source solvers provided by optional packages::

        sage: p = MixedIntegerLinearProgram(solver="CVXPY/GLPK"); p.solve()             # needs cvxopt
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/GLPK_MI"); p.solve()          # needs cvxopt
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/CVXOPT"); p.solve()           # needs cvxopt
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/GLOP"); p.solve()            # optional - ortools
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/PDLP"); p.solve()            # optional - ortools
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/CBC"); p.solve()             # optional - cylp
        0.0

    Non-free solvers::

        sage: p = MixedIntegerLinearProgram(solver="CVXPY/Gurobi"); p.solve()          # optional - gurobi
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/CPLEX"); p.solve()           # optional - cplex
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/MOSEK"); p.solve()           # optional - mosek
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/SCIP"); p.solve()            # optional - pyscipopt
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/XPRESS"); p.solve()          # optional - xpress
        0.0
        sage: p = MixedIntegerLinearProgram(solver="CVXPY/NAG"); p.solve()             # optional - naginterfaces
        0.0
    """

    def __cinit__(self, maximization=True, base_ring=None, sparse=None, implementation=None,
                  cvxpy_solver=None, cvxpy_solver_args=None):
        """
        Cython constructor

        INPUT:

        - ``maximization`` -- boolean (default: ``True``); whether this is a
          maximization or minimization problem.

        - ``base_ring`` -- (optional); must be ``RDF`` if provided.

        - ``cvxpy_solver -- (optional); passed to :meth:`cvxpy.Problem.solve` as the
          parameter ``solver``.

        - ``cvxpy_solver_args`` -- dict (optional); passed to :meth:`cvxpy.Problem.solve`
          as additional keyword arguments.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
        """
        self._cvxpy_solver = cvxpy_solver
        self._cvxpy_solver_args = cvxpy_solver_args

    def _init_base_ring(self, base_ring=None):
        r"""
        Handle a ``base_ring`` parameter passed to the constructor.

        This implementation only allows to pass ``RDF``.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY", base_ring=RDF)  # indirect doctest
            sage: p = get_solver(solver="CVXPY", base_ring=QQ)
            Traceback (most recent call last):
            ...
            ValueError: ...
        """
        if base_ring != RDF and base_ring is not None:
            raise ValueError('base_ring must be RDF')

        self._base_ring = RDF

    def init_cvxpy_problem(self, maximization, cvxpy_solver=None, cvxpy_solver_args=None):
        r"""
        Create a :class:`cvxpy.Problem` from the stored data.
        """
        if cvxpy_solver_args is None:
            cvxpy_solver_args = {}

        if isinstance(cvxpy_solver, str):
            cvxpy_solver = cvxpy_solver.upper()
            if cvxpy_solver.startswith("SCIPY/"):
                cvxpy_solver_args['scipy_options'] = {"method": cvxpy_solver[len("SCIPY/"):]}
                cvxpy_solver = "SCIPY"
            cvxpy_solver = getattr(cvxpy, cvxpy_solver)
        self._cvxpy_solver = cvxpy_solver
        self._cvxpy_solver_args = cvxpy_solver_args

        self.set_verbosity(0)

        self.variables = []
        for j in range(self.ncols()):
            lower_bound, upper_bound = self.col_bounds(j)
            binary = self.is_binary[j]
            continuous = self.is_continuous[j]
            integer = self.is_integer[j]
            name = self.col_name(j)
            self.variables.append(self._cvxpy_variable(lower_bound, upper_bound,
                                                       binary, continuous, integer, name))

        if self.variables:
            expr = AddExpression([c * x for c, x in zip(self.objective_coefficients[0], self.variables)])
        else:
            expr = Constant(0)
        if maximization:
            objective = cvxpy.Maximize(expr)
        else:
            objective = cvxpy.Minimize(expr)

        constraints = []
        for i in range(self.nrows()):
            constraints.extend(self._cvxpy_constraints(zip(*self.row(i)), *self.row_bounds(i)))

        self.problem = cvxpy.Problem(objective, constraints)

    cpdef __copy__(self):
        """
        Return a copy of ``self``.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = MixedIntegerLinearProgram(solver="CVXPY")
            sage: b = p.new_variable()
            sage: p.add_constraint(b[1] + b[2] <= 6)
            sage: p.set_objective(b[1] + b[2])
            sage: cp = copy(p.get_backend())
            sage: cp.solve()
            0
            sage: cp.get_objective_value()  # abs tol 1e-7
            6.0
        """
        cdef CVXPYBackend cp = super(CVXPYBackend, self).__copy__()
        cp.problem = self.problem                   # it's considered immutable; so no need to copy.
        cp.variables = copy(self.variables)
        return cp

    cpdef cvxpy_problem(self):
        r"""
        Return the :class:`cvxpy.Problem`.
        """
        return self.problem

    def cvxpy_variables(self):
        r"""
        Return a list of the :class:`cvxpy.Variable` objects.
        """
        return self.variables

    def _cvxpy_variable(self, lower_bound, upper_bound, binary, continuous, integer, name):
        if binary:
            variable = cvxpy.Variable(name=name, boolean=True)
        elif integer:
            variable = cvxpy.Variable(name=name, integer=True)
        else:
            variable = cvxpy.Variable(name=name)
        return variable

    cpdef int add_variable(self, lower_bound=0, upper_bound=None,
                           binary=False, continuous=True, integer=False,
                           obj=None, name=None, coefficients=None) except -1:
        # coefficients is an extension in this backend,
        # and a proposed addition to the interface, to unify this with add_col.
        """
        Add a variable.

        This amounts to adding a new column to the matrix. By default,
        the variable is both nonnegative and real.

        INPUT:

        - ``lower_bound`` - the lower bound of the variable (default: 0)

        - ``upper_bound`` - the upper bound of the variable (default: ``None``)

        - ``binary`` - ``True`` if the variable is binary (default: ``False``).

        - ``continuous`` - ``True`` if the variable is continuous (default: ``True``).

        - ``integer`` - ``True`` if the variable is integral (default: ``False``).

        - ``obj`` - (optional) coefficient of this variable in the objective function (default: 0)

        - ``name`` - an optional name for the newly added variable (default: ``None``).

        - ``coefficients`` -- (optional) an iterable of pairs ``(i, v)``. In each
          pair, ``i`` is a row index (integer) and ``v`` is a
          value (element of :meth:`base_ring`).

        OUTPUT: The index of the newly created variable

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.ncols()
            0
            sage: p.add_variable()
            0
            sage: p.ncols()
            1
            sage: p.add_variable(continuous=True, integer=True)
            Traceback (most recent call last):
            ...
            ValueError: ...
            sage: p.add_variable(name='x', obj=1)
            1
            sage: p.col_name(1)
            'x'
            sage: p.objective_coefficient(1)
            1.0
            sage: p.objective_coefficient(1).parent()
            Real Double Field
        """
        cdef int vtype = int(binary) + int(continuous) + int(integer)
        if vtype == 0:
            continuous = True
        elif vtype != 1:
            raise ValueError("Exactly one parameter of 'binary', 'integer' and 'continuous' must be 'True'.")

        index = super(CVXPYBackend, self).add_variable(lower_bound, upper_bound,
                                                       binary, continuous, integer,
                                                       obj, name, coefficients)
        if self.problem is None:
            pass
        else:
            name = self.col_name(index)
            variable = self._cvxpy_variable(lower_bound, upper_bound, binary, continuous, integer, name)
            constraints = self.problem.constraints

            if coefficients is not None:
                constraints = list(constraints)
                for i, v in coefficients:
                    if not isinstance(constraints[i], Equality):
                        # adding coefficients to inequalities is ambiguous
                        # because cvxpy rewrites all inequalities as <=
                        # - so just re-create the problem on next 'solve'
                        self.problem = self.variables = None
                        self.add_linear_constraint([(index, 1)], lower_bound, upper_bound)
                        return index

                    constraints[i] = type(constraints[i])(constraints[i].args[0] + float(v) * variable,
                                                          constraints[i].args[1])
            objective = self.problem.objective
            if obj:
                objective = type(objective)(self.problem.objective.args[0] + obj * variable)

            self.problem = cvxpy.Problem(objective, constraints)
            self.variables.append(variable)

        self.add_linear_constraint([(index, 1)], lower_bound, upper_bound)
        return index

    cpdef set_verbosity(self, int level):
        """
        Set the log (verbosity) level

        This is currently ignored.

        INPUT:

        - ``level`` (integer) -- From 0 (no verbosity) to 3.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.set_verbosity(2)
        """
        pass

    def _cvxpy_constraints(self, coefficients, lower_bound, upper_bound):
        r"""
        Return a list of :class:`cvxpy.Constraint` objects that express
        ``lower_bound <= coefficients * variables <= upper_bound``.

        INPUT:

        - ``coefficients`` -- an iterable of pairs ``(i, v)``. In each
          pair, ``i`` is a variable index (integer) and ``v`` is a
          value (element of :meth:`base_ring`).

        - ``lower_bound`` -- element of :meth:`base_ring` or
          ``None``. The lower bound.

        - ``upper_bound`` -- element of :meth:`base_ring` or
          ``None``. The upper bound.
        """
        constraints = []
        terms = [v * self.variables[i] for i, v in coefficients]
        if terms:
            expr = AddExpression(terms)
        else:
            expr = Constant(0)
        if lower_bound is not None and lower_bound == upper_bound:
            constraints.append(expr == upper_bound)
        else:
            if lower_bound is not None:
                constraints.append(lower_bound <= expr)
            if upper_bound is not None:
                constraints.append(expr <= upper_bound)
        return constraints

    cpdef add_linear_constraint(self, coefficients, lower_bound, upper_bound, name=None):
        """
        Add a linear constraint.

        INPUT:

        - ``coefficients`` -- an iterable of pairs ``(i, v)``. In each
          pair, ``i`` is a variable index (integer) and ``v`` is a
          value (element of :meth:`base_ring`).

        - ``lower_bound`` -- element of :meth:`base_ring` or
          ``None``. The lower bound.

        - ``upper_bound`` -- element of :meth:`base_ring` or
          ``None``. The upper bound.

        - ``name`` -- string or ``None``. Optional name for this row.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.add_variables(5)
            4
            sage: index = p.nrows()
            sage: p.add_linear_constraint( zip(range(5), range(5)), 2, 2)
            sage: p.row(index)
            ([1, 2, 3, 4], [1.0, 2.0, 3.0, 4.0])
            sage: p.row_bounds(index)
            (2.0, 2.0)
            sage: p.add_linear_constraint( zip(range(5), range(5)), 1, 1, name='foo')
            sage: p.row_name(1)
            'constraint_1'
        """
        super(CVXPYBackend, self).add_linear_constraint(coefficients, lower_bound, upper_bound, name)

        if self.problem is None:
            pass
        else:
            constraints = self.problem.constraints + self._cvxpy_constraints(coefficients, lower_bound, upper_bound)
            self.problem = cvxpy.Problem(self.problem.objective, constraints)

    cpdef set_objective(self, list coeff, d=0.0):
        """
        Set the objective function.

        INPUT:

        - ``coeff`` -- a list of real values, whose ith element is the
          coefficient of the ith variable in the objective function.

        - ``d`` (double) -- the constant term in the linear function (set to `0` by default)

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.add_variables(5)
            4
            sage: p.set_objective([1, 1, 2, 1, 3])
            sage: [p.objective_coefficient(x) for x in range(5)]
            [1.0, 1.0, 2.0, 1.0, 3.0]
        """
        super(CVXPYBackend, self).set_objective(coeff, d)

        if self.problem is None:
            pass
        else:
            if self.variables:
                expr = AddExpression([c * x for c, x in zip(coeff, self.variables)])
            else:
                expr = Constant(0)
            objective = type(self.problem.objective)(expr)
            constraints = list(self.problem.constraints)
            self.problem = cvxpy.Problem(objective, constraints)

    cpdef set_sense(self, int sense):
        """
        Set the direction (maximization/minimization).

        INPUT:

        - ``sense`` (integer):

          * +1 => Maximization
          * -1 => Minimization

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.is_maximization()
            True
            sage: p.set_sense(-1)
            sage: p.is_maximization()
            False
        """
        super(CVXPYBackend, self).set_sense(sense)

        if self.problem is None:
            pass
        else:
            expr = self.problem.objective.args[0]
            if sense == 1:
                objective = cvxpy.Maximize(expr)
            else:
                objective = cvxpy.Minimize(expr)
            self.problem = cvxpy.Problem(objective, self.problem.constraints)

    cpdef objective_coefficient(self, int variable, coeff=None):
        """
        Set or get the coefficient of a variable in the objective function

        INPUT:

        - ``variable`` (integer) -- the variable's id

        - ``coeff`` (double) -- its coefficient or ``None`` for
          reading (default: ``None``)

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.add_variable()
            0
            sage: p.objective_coefficient(0)
            0.0
            sage: p.objective_coefficient(0, 2)
            sage: p.objective_coefficient(0)
            2.0
        """
        if coeff is not None:
            super(CVXPYBackend, self).objective_coefficient(variable, coeff)
            if self.problem is None:
                pass
            else:
                expr = self.problem.objective.args[0] + coeff * self.variables[variable]  # FIXME: Wrong if variable already had a nonzero coeff
                objective = type(self.problem.objective)(expr)
                constraints = list(self.problem.constraints)
                self.problem = cvxpy.Problem(objective, constraints)
        else:
            return super(CVXPYBackend, self).objective_coefficient(variable, coeff)

    cpdef int solve(self) except -1:
        """
        Solve the problem.

        .. NOTE::

            This method raises ``MIPSolverException`` exceptions when
            the solution cannot be computed for any reason (none
            exists, or the LP solver was not able to find it, etc...)

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.add_linear_constraints(5, 0, None)
            sage: p.add_col(list(range(5)), list(range(5)))
            sage: p.solve()
            0
            sage: p.objective_coefficient(0, 1)
            sage: p.solve()
            Traceback (most recent call last):
            ...
            MIPSolverException: ...
        """
        if not self.problem:
            self.init_cvxpy_problem(self.is_maximize, self._cvxpy_solver, self._cvxpy_solver_args)

        try:
            self.problem.solve(solver=self._cvxpy_solver, **self._cvxpy_solver_args)
        except Exception as e:
            raise MIPSolverException(f"cvxpy.Problem.solve raised exception: {e}")

        status = self.problem.status
        if 'optimal' in status:
            return 0
        if 'infeasible' in status:
            raise MIPSolverException(f"cvxpy.Problem.solve: Problem has no feasible solution")
        if 'unbounded' in status:
            raise MIPSolverException(f"cvxpy.Problem.solve: Problem is unbounded")
        raise MIPSolverException(f"cvxpy.Problem.solve reported an unknown problem status: {status}")

    cpdef get_objective_value(self):
        """
        Return the value of the objective function.

        .. NOTE::

           Behavior is undefined unless ``solve`` has been called before.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.add_variables(2)
            1
            sage: p.add_linear_constraint([(0,1), (1,2)], None, 3)
            sage: p.set_objective([2, 5])
            sage: p.solve()
            0
            sage: p.get_objective_value()  # abs tol 1e-7
            7.5
            sage: p.get_variable_value(0)  # abs tol 1e-7
            0.0
            sage: p.get_variable_value(1)  # abs tol 1e-7
            1.5
        """
        return self.problem.value + self.obj_constant_term

    cpdef get_variable_value(self, int variable):
        """
        Return the value of a variable given by the solver.

        .. NOTE::

           Behavior is undefined unless ``solve`` has been called before.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.add_variables(2)
            1
            sage: p.add_linear_constraint([(0,1), (1, 2)], None, 3)
            sage: p.set_objective([2, 5])
            sage: p.solve()
            0
            sage: p.get_objective_value()  # abs tol 1e-7
            7.5
            sage: p.get_variable_value(0)  # abs tol 1e-7
            0.0
            sage: p.get_variable_value(1)  # abs tol 1e-7
            1.5
        """
        return float(self.variables[variable].value)

    cpdef problem_name(self, name=None):
        """
        Return or define the problem's name

        INPUT:

        - ``name`` (``str``) -- the problem's name. When set to
          ``None`` (default), the method returns the problem's name.

        EXAMPLES::

            sage: from sage.numerical.backends.generic_backend import get_solver
            sage: p = get_solver(solver="CVXPY")
            sage: p.problem_name("There_once_was_a_french_fry")
            sage: print(p.problem_name())
            There_once_was_a_french_fry
        """
        if name is None:
            if self.prob_name is not None:
                return self.prob_name
            else:
                return ""
        else:
            self.prob_name = str(name)
