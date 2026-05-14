.. _relational_modeling:

Relational Modeling for APIs
############################

PostgREST works best when the database schema describes the business facts of an application.
Tables, keys, foreign keys, constraints, views, functions and permissions are the API contract.

This does not mean that every rule must be reduced to a table definition.
Use relations and constraints for facts and invariants, use views for derived facts, and use :ref:`functions <functions>` for commands that are genuinely procedural.
The goal is to make invalid states impossible to store before adding imperative code.

PostgREST exposes :ref:`tables and views <tables_views>` as resources, uses foreign keys for :ref:`resource_embedding`, calls :ref:`functions <functions>` under ``/rpc`` and runs every request inside a :ref:`transaction <transactions>`.
Those features work best when the schema carries the same business meaning that the API is expected to enforce.

Common API Smells
=================

Some API feature requests are signs that the relational model is missing a business fact.
Before adding a function or a custom endpoint, check whether the rule can be expressed by the schema.

.. list-table::
   :header-rows: 1

   * - If the client needs...
     - Look for...
   * - Nested writes across several tables
     - A missing aggregate relation, line item relation, join table, or command function
   * - Joins not supported by resource embedding
     - Missing foreign keys, a view, or a :ref:`computed relationship <computed_relationships>`
   * - A transaction across several HTTP requests
     - A missing business event relation, or a command that belongs in one function call
   * - Upsert based on application logic
     - A missing primary key, unique constraint, or composite business key
   * - Validation before insert or update
     - A missing domain, check constraint, foreign key, exclusion constraint, subtype table, or row-level security policy

Normal Forms as Design Tools
============================

Normal forms are practical tools for moving business logic from imperative code into the data model.
They are not only about reducing storage duplication.

In this guide:

- Fifth normal form is useful when one row combines several independent facts.
  Decomposing those facts lets foreign keys enforce which combinations are valid.
- Domain-key normal form is useful as a design ideal: prefer rules that follow from domains, keys and references.
  If a value has a reusable rule, make it a domain or lookup relation.
  If a row has a business identity, make it a key.
  If a reference is only valid in a scope or subtype, include that scope or subtype in the referenced relation.

Not every invariant can be expressed in domain and key constraints.
For those cases, use PostgreSQL's other declarative constraints where possible, and keep functions focused on the remaining procedural command.

Model Business Events
=====================

A common account model stores the current balance on the account row:

.. code-block:: postgres

  create table accounts (
    id bigint primary key,
    balance numeric not null check (balance >= 0)
  );

A transfer then requires subtracting from one account and adding to another account.
That can be implemented by a :ref:`function <functions>`, and because each PostgREST request runs in a :ref:`transaction <transactions>`, that function call is atomic.
However, if transfers are the real business facts, the schema can model them directly:

.. code-block:: postgres

  create table accounts (
    id bigint primary key
  );

  create table account_transactions (
    id bigint generated always as identity primary key,
    debit_account_id bigint not null references accounts(id),
    credit_account_id bigint not null references accounts(id),
    amount numeric not null check (amount > 0),
    created_at timestamptz not null default now(),
    check (debit_account_id <> credit_account_id)
  );

The invariant is now simpler: one transaction row references two different accounts and a positive amount.
The current balance is a derived fact:

.. code-block:: postgres

  create view account_balances as
  with sum_credits as (
    select credit_account_id as account_id, sum(amount) as credits
    from account_transactions
    group by credit_account_id
  ),
  sum_debits as (
    select debit_account_id as account_id, sum(amount) as debits
    from account_transactions
    group by debit_account_id
  )
  select
    coalesce(sum_credits.account_id, sum_debits.account_id) as account_id,
    coalesce(credits, 0) - coalesce(debits, 0) as balance
  from sum_credits
  full outer join sum_debits using (account_id);

Expose the ``account_transactions`` relation for creating transfers and the ``account_balances`` view for reading balances.
If the system must reject overdrafts, add a function that inserts the transaction while taking the appropriate locks or using the appropriate isolation level.
The function is then limited to the irreducibly procedural rule; the durable business history remains relational.

Carry Scope in Composite Keys
=============================

Applications often have scoped identifiers: a product SKU is unique within a tenant, a document number is unique within a project, or a user role is valid within one organization.
If that scope is part of the business identity, carry it in the key and in the foreign key.

.. code-block:: postgres

  create table tenants (
    id uuid primary key
  );

  create table products (
    tenant_id uuid not null references tenants(id),
    sku text not null,
    name text not null,
    primary key (tenant_id, sku)
  );

  create table orders (
    tenant_id uuid not null references tenants(id),
    id bigint not null,
    primary key (tenant_id, id)
  );

  create table order_lines (
    tenant_id uuid not null,
    order_id bigint not null,
    line_no int not null,
    product_sku text not null,
    quantity int not null check (quantity > 0),
    primary key (tenant_id, order_id, line_no),
    foreign key (tenant_id, order_id)
      references orders (tenant_id, id),
    foreign key (tenant_id, product_sku)
      references products (tenant_id, sku)
  );

This prevents an order line in one tenant from referencing a product in another tenant.
The rule is not an application precondition; it is part of the stored fact.

Composite keys also improve PostgREST behavior.
:ref:`Resource embedding <resource_embedding>` respects composite foreign keys, and :ref:`upsert <upsert>` works best when the primary key or ``on_conflict`` target is the real business identity.

Use Join Tables for Many-to-Many Facts
======================================

Many-to-many relationships are not attributes; they are facts.
For example, event participation should be modeled as a relation:

.. code-block:: postgres

  create table events (
    id bigint primary key,
    name text not null
  );

  create table people (
    id bigint primary key,
    name text not null
  );

  create table event_participants (
    event_id bigint not null references events(id),
    person_id bigint not null references people(id),
    role text not null check (role in ('speaker', 'attendee', 'organizer')),
    primary key (event_id, person_id)
  );

This gives the relationship its own constraints and attributes.
It also matches PostgREST's :ref:`many-to-many embedding <many-to-many>`: a join table is detected when its foreign keys are part of its composite key.

Model Subtypes as Relations
===========================

If a row may only reference a subset of another table, avoid hiding that rule in application code.
When the subset is a real business concept, model it as a relation.

.. code-block:: postgres

  create table employees (
    id bigint primary key,
    name text not null
  );

  create table inspectors (
    employee_id bigint primary key references employees(id)
  );

  create table inspections (
    id bigint primary key,
    inspector_id bigint not null references inspectors(employee_id),
    inspected_at timestamptz not null default now()
  );

An inspection cannot reference an employee who is not an inspector.
No procedure needs to query ``employees`` to check a flag.

If the subset is a simple discriminator rather than a separate business concept, PostgreSQL can still enforce it with a composite foreign key and a check constraint:

.. code-block:: postgres

  create table employees (
    id bigint primary key,
    name text not null,
    is_inspector boolean not null,
    unique (id, is_inspector)
  );

  create table inspections (
    id bigint primary key,
    inspector_id bigint not null,
    is_inspector boolean not null default true check (is_inspector),
    foreign key (inspector_id, is_inspector)
      references employees (id, is_inspector)
  );

Prefer the subtype table when the role has its own lifecycle, permissions, attributes, or relationships.

Decompose Independent Facts
===========================

Fifth normal form is useful when a relation combines facts that vary independently.
For example, a delivery may be valid only when all three facts are true:

- The supplier supplies the part.
- The project uses the part.
- The supplier is approved for the project.

Model those facts separately and let the delivery reference all of them:

.. code-block:: postgres

  create table supplier_parts (
    supplier_id bigint,
    part_id bigint,
    primary key (supplier_id, part_id)
  );

  create table project_parts (
    project_id bigint,
    part_id bigint,
    primary key (project_id, part_id)
  );

  create table project_suppliers (
    project_id bigint,
    supplier_id bigint,
    primary key (project_id, supplier_id)
  );

  create table deliveries (
    project_id bigint,
    supplier_id bigint,
    part_id bigint,
    delivered_at timestamptz not null default now(),
    primary key (project_id, supplier_id, part_id, delivered_at),
    foreign key (supplier_id, part_id)
      references supplier_parts (supplier_id, part_id),
    foreign key (project_id, part_id)
      references project_parts (project_id, part_id),
    foreign key (project_id, supplier_id)
      references project_suppliers (project_id, supplier_id)
  );

The ``deliveries`` table cannot contain a supplier, part and project combination unless all three independent business facts exist.
This is the practical value of higher normal forms: the database enforces the valid recomposition of facts.

Use Constraints for Non-Key Rules
=================================

Some invariants are not only about identity or relationships.
PostgreSQL has several declarative tools that keep these rules close to the data:

- ``not null`` and ``check`` constraints for local row invariants.
- Domains for reusable value rules, which can also be exposed through :ref:`domain representations <domain_reps>`.
- ``unique`` constraints for alternate keys and idempotent writes.
- Foreign keys for cross-table facts.
- Exclusion constraints for conflicts such as overlapping reservations.
- Row-level security for authorization rules, as described in :ref:`db_authz`.

For example, a room should not have overlapping bookings.
Checking availability in the client and then inserting can race with another request.
An exclusion constraint makes the conflict unrepresentable:

.. code-block:: postgres

  create extension if not exists btree_gist;

  create table room_bookings (
    room_id bigint not null,
    during tstzrange not null,
    exclude using gist (
      room_id with =,
      during with &&
    )
  );

PostgREST does not need a special endpoint for this rule.
Clients can insert into ``room_bookings``; PostgreSQL accepts valid bookings and rejects conflicting ones.

Expose Views for Derived Facts
==============================

If clients need a representation that is derived from normalized tables, expose a view instead of duplicating data.
Views are first-class API resources in PostgREST and can participate in :ref:`foreign key joins <embedding_views>` when the relevant key columns are present.

Examples include:

- Account balances derived from ledger entries.
- Available stock derived from stock movements and allocations.
- Order totals derived from order lines.
- Effective permissions derived from memberships and roles.

When a view is part of the public API, consider the :ref:`schema isolation <schema_isolation>` pattern: keep implementation tables in a private schema and expose stable views and functions through the API schema.

Model State Changes as Facts
============================

Lifecycle changes often look like operations: approve an order, cancel a booking, publish a document.
Before creating a function for the verb, check whether the operation is really a new fact that should be recorded.

For example, an order approval can be modeled as a relation:

.. code-block:: postgres

  create table orders (
    id bigint primary key,
    customer_id bigint not null,
    created_at timestamptz not null default now()
  );

  create table order_approvers (
    order_id bigint not null references orders(id),
    approver_id bigint not null,
    primary key (order_id, approver_id)
  );

  create table order_approvals (
    order_id bigint primary key references orders(id),
    approver_id bigint not null default (
      (current_setting('request.jwt.claims', true)::jsonb ->> 'employee_id')::bigint
    ),
    approved_at timestamptz not null default now(),
    comment text,
    foreign key (order_id, approver_id)
      references order_approvers (order_id, approver_id)
  );

This records who approved the order, when it happened and any additional details.
The primary key also enforces that an order can be approved only once.
The ``order_approvers`` relation records who is allowed to approve each order.
The composite foreign key makes an approval invalid unless that authorization fact exists.

Since approval is an insert into ``order_approvals``, access control can use normal database authorization.
For example, grant access to the columns a client should provide and let defaults fill the actor and timestamp:

.. code-block:: postgres

  grant insert (order_id, comment) on order_approvals to webuser;

If clients share a database role, combine this with :ref:`row-level security <db_authz>` so the row must match the current request:

.. code-block:: postgres

  alter table order_approvals enable row level security;

  create policy approve_allowed_orders on order_approvals
    for insert
    with check (
      approver_id = (
        current_setting('request.jwt.claims', true)::jsonb ->> 'employee_id'
      )::bigint
    );

The business rule "only assigned approvers can approve this order" is enforced by relation privileges, a default, row-level security and a foreign key.
It does not need to be hidden inside an ``approve_order`` function.

If approval can be withdrawn or repeated, use an ``order_events`` relation instead:

.. code-block:: postgres

  create table order_events (
    order_id bigint not null references orders(id),
    event_no int not null,
    event_type text not null check (event_type in ('approved', 'cancelled', 'reopened')),
    actor_id bigint not null,
    happened_at timestamptz not null default now(),
    details jsonb not null default '{}',
    primary key (order_id, event_no)
  );

Current order state is then a derived fact exposed through a view.
The schema stores the business history instead of overwriting it with a status update.

Separate State Changes from External Effects
============================================

Do not mix database changes and communication with external systems in one database transaction.
The database can roll back its own changes, but it cannot roll back an email that was sent, a payment provider request that was accepted, or a webhook delivered to another service.
It also makes database scalability depend on the latency of the external system.
While the transaction waits for an external response, a database connection remains borrowed from the pool and any locks taken by the transaction remain held.
Under load, slow external calls can therefore exhaust connection pools, increase lock contention and reduce throughput for unrelated API requests.

A useful pattern is to treat the database as the source of truth about system state:

- Commands are database transactions that record facts.
- Current state is derived from recorded facts using views.
- Work to perform is derived from current state using ``select`` statements or views.
- Separate workers perform external actions and record each attempt and result as more facts.

The information flow forms a processing loop:

.. container:: img-dark

  .. raw:: html

    <object width="100%" data="../_static/cqrs-dark.svg" type="image/svg+xml"></object>

.. container:: img-light

  .. raw:: html

    <object width="100%" data="../_static/cqrs.svg" type="image/svg+xml"></object>

This is a CQRS-style split.
The write side records facts such as order creation, approval, cancellation and external action results.
The read side exposes views over those facts.
External actions are not performed inside the command transaction; they are consequences of state recorded in the database.

For example, after an order is approved, the system may need to notify a fulfillment service:

.. code-block:: postgres

  create table fulfillment_requests (
    order_id bigint primary key references orders(id),
    requested_at timestamptz not null default now()
  );

  create table fulfillment_attempts (
    id bigint generated always as identity primary key,
    order_id bigint not null references fulfillment_requests(order_id),
    attempted_at timestamptz not null default now(),
    provider text not null,
    request jsonb not null,
    response jsonb,
    succeeded boolean
  );

The command transaction records the approval and, if fulfillment is now required, the fulfillment request:

.. code-block:: postgres

  insert into order_approvals (order_id, comment)
  values (42, 'Ready to ship');

  insert into fulfillment_requests (order_id)
  values (42);

The action to perform can be derived declaratively:

.. code-block:: postgres

  create view pending_fulfillment_requests as
  select fulfillment_requests.order_id
  from fulfillment_requests
  join order_approvals using (order_id)
  where not exists (
    select 1
    from fulfillment_attempts
    where fulfillment_attempts.order_id = fulfillment_requests.order_id
    and fulfillment_attempts.succeeded
  );

A worker reads ``pending_fulfillment_requests``, calls the fulfillment provider outside the database transaction, and records the result in ``fulfillment_attempts``.
If the process fails halfway through, the database still records what is known: the order was approved, fulfillment was requested and perhaps an attempt was made.
Retries, dashboards and audits can all be based on relations and views rather than on hidden control flow.

This turns the system into an explicit state machine.
Events are facts in tables, current state is a query over those facts, and external work is another query over state.
Functions may still be useful for recording a command atomically, but they should record the facts and requested effects, not perform irreversible external communication while the transaction is open.

Use Functions for Commands
==========================

Functions are the right tool when the operation is a command rather than a stored fact.
Use them for:

- Operations that require explicit locking or a custom isolation level.
- Workflows that must validate several facts and then perform several changes.
- Security-definer boundaries over private tables.
- Operations with side effects outside the exposed resource model.
- Custom queries that exceed the :ref:`URL grammar <custom_queries>`.

Keep the relational model responsible for the facts that remain after the command completes.
A function may still be useful when creating an approval requires locks, permission checks or coordination with other tables.
In that case, the function should insert into ``order_approvals`` or ``order_events`` rather than making the approval disappear into procedure-local logic.

Design Checklist
================

Before adding procedural logic, ask:

- What is the business fact being stored?
- What is the natural or composite key for that fact?
- Does every real relationship have a foreign key?
- Is the relationship itself a fact that needs a join table?
- Is a mutable column actually derived from event or ledger rows?
- Can a subtype table replace a ``type`` or ``is_*`` check in code?
- Can a check, domain, unique, foreign key or exclusion constraint make the invalid state impossible?
- Would a view expose the read model without duplicating data?
- Is the remaining operation truly a command that belongs in a function?

When the schema answers these questions, the generated API becomes smaller and more predictable.
PostgREST can focus on exposing database resources while PostgreSQL enforces the rules that define those resources.
