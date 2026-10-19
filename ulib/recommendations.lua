-- ulib/recommendations.lua
-- Чистая логика оценки и сортировки советов: без API игры, чтобы её можно было тестировать отдельно.

local Recommendations = {}

-- vs: { угроза = эффективность предмета }, threats: { угроза = { total = сила } },
-- fit: насколько предмет подходит герою (0..1), cover: доля уже закрытой угрозы.
-- Возвращает суммарную оценку и части для объяснения совета.
function Recommendations.Score(vs, threats, fit, cover)
    local score, parts = 0, {}
    if fit <= 0 then
        return score, parts
    end

    for threat, effectiveness in pairs(vs) do
        local total = threats[threat]
        if total and effectiveness > 0 then
            local adjusted = effectiveness * fit * (1 - (cover[threat] or 0))
            local part_score = adjusted * total.total
            score = score + part_score
            parts[#parts + 1] = { threat = threat, eff = adjusted, score = part_score }
        end
    end
    return score, parts
end

-- Совет, уже отображавшийся игроку, удерживается до 80% порога, чтобы не мигать у границы.
function Recommendations.MeetsThreshold(score, threshold, was_shown, hysteresis)
    return score >= threshold or (was_shown and score >= threshold * (hysteresis or 0.8))
end

-- Сортировка по оценке, затем по id для стабильного порядка при равных оценках.
function Recommendations.Sort(recommendations)
    table.sort(recommendations, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return a.id < b.id
    end)
    return recommendations
end

return Recommendations
