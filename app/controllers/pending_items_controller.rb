# Fills in exactly one value the pipeline couldn't populate, identified by
# (scope, field, position) rather than a synthetic id — kind + field + scope +
# position is already unique per resume, since Resume::Extractors::Llm and
# Resume::Import only ever record one pending item per field per row.
#
# Deliberately narrow (ADR-0031): FILLABLE_FIELDS excludes "experience" and
# "education" (a whole dropped entry) on purpose — recreating one means typing
# company *and* title *and* dates *and* bullets, which is full CRUD on
# Experience/Education, not "fill a field." Those stay inform-only in the view,
# with no form pointed at this action, and even a crafted request for one 404s
# here since FILLABLE_FIELDS is the actual gate, not just the view.
#
# No FidelityCheck, no LLM call on the submitted value: it's the resume
# owner's own first-party assertion about their own life, not LLM output
# being laundered past verification. FidelityCheck has no jurisdiction over
# a user's word against their own word — see ADR-0031.
class PendingItemsController < ApplicationController
  FILLABLE_FIELDS = %w[name email phone summary location starts_on ends_on skill bullet].freeze

  def create
    @resume = find_owned_resume!(params[:resume_id])
    item_params = params.require(:pending_item).permit(:scope, :field, :position, :value)

    unless FILLABLE_FIELDS.include?(item_params[:field])
      head :not_found and return
    end

    record, items = target_record(item_params[:scope], item_params[:position])
    item = items&.find { |candidate| candidate["field"] == item_params[:field] }

    if record.nil? || item.nil?
      head :not_found and return
    end

    apply_value!(record, item_params[:field], item_params[:value].to_s)
    record.pending_items = items - [ item ]
    record.save!

    respond_to do |format|
      format.html { redirect_to resume_path(@resume) }
      format.turbo_stream { render turbo_stream: turbo_stream.update("main_content", template: "resumes/show") }
    end
  rescue ArgumentError
    # Date.iso8601 on a value the type="date" input didn't actually produce
    # (a hand-crafted request, not a real browser submission).
    flash.now[:alert] = "That value couldn't be saved. Please try again."
    respond_to do |format|
      format.html { render "resumes/show", status: :unprocessable_entity }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update("flash", partial: "layouts/flash"),
          turbo_stream.update("main_content", template: "resumes/show")
        ], status: :unprocessable_entity
      end
    end
  end

  private

  def target_record(scope, position)
    case scope
    when "resume"
      [ @resume, @resume.pending_items ]
    when "experience"
      experience = @resume.experiences.find_by(position: position)
      [ experience, experience&.pending_items ]
    when "education"
      education = @resume.educations.find_by(position: position)
      [ education, education&.pending_items ]
    else
      [ nil, nil ]
    end
  end

  def apply_value!(record, field, value)
    case field
    when "starts_on", "ends_on" then record[field] = Date.iso8601(value)
    when "skill" then record.skills += [ value ]
    when "bullet" then record.bullets += [ value ]
    else record[field] = value
    end
  end
end
