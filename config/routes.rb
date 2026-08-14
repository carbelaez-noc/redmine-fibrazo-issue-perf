RedmineApp::Application.routes.draw do
  get 'issues/:id/lazy_edit_attributes',
      to: 'issues#lazy_edit_attributes',
      as: 'lazy_edit_issue_attributes'
end
