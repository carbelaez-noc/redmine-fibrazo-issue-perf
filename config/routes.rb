RedmineApp::Application.routes.draw do
  get 'issues/:id/lazy_edit_form', to: 'issues#lazy_edit_form', as: 'lazy_edit_issue_form'
end
