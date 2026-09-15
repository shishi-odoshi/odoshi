# frozen_string_literal: true
module Odoshi
  # DESIGN §3.3, group-aware since 0.4.0 (P1 replicas). The tree is an ordered
  # list of SLOTS; a slot is either a single child or a replica group whose
  # members are interchangeable peers. Declaration order encodes dependency
  # BETWEEN slots, never within one.
  #
  # Given the ordered slots (arrays of ids) and the failed id, return the
  # ordered ids that must be stopped and restarted:
  # - one_for_one:  just the failed child — a replica crash never touches its
  #   peers (they are peers, not dependents).
  # - rest_for_one: order encodes dependency on a slot's SERVICE. A singleton
  #   slot failing takes its service down ⇒ the failed child plus every id in
  #   later slots restarts. A replica (multi-member slot) failing does NOT
  #   take the service down — its peers kept serving — so only the failed
  #   replica restarts and dependents keep running. When an EARLIER slot
  #   fails, every member of this group restarts with it (via the fan-out).
  # - one_for_all:  everything.
  module Strategy
    KINDS = %i[one_for_one rest_for_one one_for_all].freeze

    def self.affected(kind, slots, failed_id)
      raise ConfigError, "unknown strategy #{kind}" unless KINDS.include?(kind)
      idx = slots.index { |slot| slot.include?(failed_id) } or
        raise ArgumentError, "#{failed_id} not in tree"
      case kind
      when :one_for_one  then [failed_id]
      when :rest_for_one then slots[idx].size > 1 ? [failed_id] : [failed_id, *slots[(idx + 1)..].flatten]
      when :one_for_all  then slots.flatten
      end
    end
  end
end
