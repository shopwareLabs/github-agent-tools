## Write (gh-tooling-write)
PRs: pr_create, pr_edit, pr_ready, pr_merge, pr_close, pr_reopen
Reviews: pr_review_submit, pr_comment, pr_review_reply
Issues: issue_create, issue_edit, issue_close, issue_reopen, issue_comment
Issue type and fields: issue_type_set, issue_field_set (issue_field_set replaces the issue's whole set of field values; read them first with issue_view and with_field_values true)
Labels: label_add, label_remove
Assignees: assignee_add, assignee_remove
Sub-issues: sub_issue_add, sub_issue_remove
Projects: project_item_add, project_status_set
Escape hatch (last resort): api (all HTTP methods). Use only when no dedicated write tool covers your endpoint — not as a fallback when a dedicated tool returns an error.
