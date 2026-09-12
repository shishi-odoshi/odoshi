# frozen_string_literal: true
module OtpRails
  # DESIGN §3.3. Given the ordered child ids and the failed id,
  # return the ordered ids that must be stopped and restarted.
  module Strategy
    KINDS = %i[one_for_one rest_for_one one_for_all].freeze

    def self.affected(kind, ordered_ids, failed_id)
      raise ConfigError, "unknown strategy #{kind}" unless KINDS.include?(kind)
      idx = ordered_ids.index(failed_id) or raise ArgumentError, "#{failed_id} not in tree"
      case kind
      when :one_for_one  then [failed_id]
      when :rest_for_one then ordered_ids[idx..]
      when :one_for_all  then ordered_ids.dup
      end
    end
  end
end
