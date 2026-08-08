Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Mandatory-accounts sign-in (issue #120, ADR-0032). :create is deliberately
  # excluded here — it's handled by the explicit OmniAuth callback route below,
  # not a form POST to /session.
  resource :session, only: %i[new destroy]
  get "/auth/failure", to: "sessions#failure"
  get "/auth/:provider/callback", to: "sessions#create"

  resources :resumes, only: %i[index new create show] do
    resource :job_description, only: :create
    resource :preview, only: :create
    resource :pending_items, only: :create
    resources :downloads, only: :create
  end
  resources :downloads, only: :show do
    member { get :ready }
  end

  # Issue #123. success/ready are GET, not resourceful members of :checkout
  # (there's no single checkout "id" route param to key off — both are keyed
  # by ?session_id=, Stripe's own Checkout Session id) — see
  # Payments::CheckoutsController. webhooks lives outside the :payments
  # resource shape entirely: it's server-to-server, authenticated by Stripe's
  # signature header rather than a session, and answered by
  # Payments::WebhooksController, which deliberately does not inherit
  # ApplicationController.
  namespace :payments do
    resource :checkout, only: %i[new create] do
      get :success, on: :collection
      get :ready, on: :collection
    end
    post "webhooks", to: "webhooks#create"
  end

  # Issue #121: a signed-in user's own resume history, not the upload form —
  # upload is reachable from there as an action, not the landing page itself.
  root "resumes#index"
end
