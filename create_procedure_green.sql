/**

ФУНКЦИИ/ПРОЦЕДУРЫ

**/

-- Функция Check_product_compliance
-- Проверяет соответствие параметров товара

CREATE OR REPLACE FUNCTION check_product_compliance(
    p_id_acceptance Acceptance.id_acceptance%type,  -- Идентификатор приемки
    p_actual_quantity Acceptance_of_goods.quantity%type,  -- Фактическое количество товара
    p_actual_date Acceptance_of_goods.date_create%type,  -- Дата приемки товара
    p_id_product Product_card.id_product%type  -- Идентификатор товара
) 
RETURNS TABLE(compliance BOOLEAN, comment TEXT) AS
$$
DECLARE
    expected_quantity INT;
    expiration_date DATE;
BEGIN
    -- Получаем ожидаемое количество товара из таблицы product_in_contract
    SELECT quantity INTO expected_quantity
    FROM product_in_contract
    WHERE id_contract = (SELECT id_contract 
                          FROM acceptance 
                          WHERE id_acceptance = p_id_acceptance)
      AND id_product = p_id_product;

    -- Получаем срок годности товара из таблицы product_card
    SELECT expiration_date INTO expiration_date
    FROM product_card
    WHERE id_product = p_id_product;

    -- Проверка на соответствие
    IF p_actual_quantity != expected_quantity THEN
        compliance := FALSE;
        comment := 'несоответствие количества';
    ELSIF expiration_date < CURRENT_DATE THEN
        compliance := FALSE;
        comment := 'истек срок годности';
    ELSE
        compliance := TRUE;
        comment := 'соответствует';
    END IF;

    -- Возврат результата
    RETURN;
END;
$$ LANGUAGE plpgsql;



-- Процедура Send_request_change_status
-- Отправляет запрос на изменение статуса


CREATE OR REPLACE FUNCTION send_request_change_status(
    p_id_accept_good Acceptance_of_goods.id_accept_good%type  -- Идентификатор товарной приемки
)
RETURNS VOID AS
$$
DECLARE
    all_checked BOOLEAN := TRUE;
    current_acceptance_status VARCHAR(20);
BEGIN
    -- Проверяем результат проверки конкретного товара
    IF EXISTS (
        SELECT 1
        FROM acceptance_of_goods
        WHERE id_accept_good = p_id_accept_good
        AND is_match = FALSE
    ) THEN
        -- Если товар не соответствует стандартам, отправляем запрос в ГК
        RAISE NOTICE 'Отправлен запрос в ГК: Товар не соответствует стандартам.';
    END IF;

    -- Проверяем, все ли товары в этой приемке прошли проверку
    FOR current_acceptance_status IN
        SELECT decision
        FROM acceptance_of_goods
        WHERE id_acceptance = (SELECT id_acceptance FROM acceptance_of_goods WHERE id_accept_good = p_id_accept_good)
    LOOP
        IF current_acceptance_status = 'в ожидании' THEN
            all_checked := FALSE;
            EXIT;  -- Выходим из цикла, если хоть один товар еще не проверен
        END IF;
    END LOOP;

    -- Если все товары проверены, обновляем статус приемки
    IF all_checked THEN
        UPDATE acceptance
        SET status = 'обработано'
        WHERE id_acceptance = (SELECT id_acceptance FROM acceptance_of_goods WHERE id_accept_good = p_id_accept_good);
    END IF;

    -- Возвращаем результат
    RETURN;
END;
$$ LANGUAGE plpgsql;

$$;



-- Процедура Register_movement_goods
-- Регистрирует перемещение товара


CREATE OR REPLACE FUNCTION register_movement_goods(
    p_id_product Moving.id_product%type,
    p_id_initial_place Moving.id_initial_place%type DEFAULT NULL,
    p_id_target_place Moving.id_target_place%type DEFAULT NULL,
    p_id_initial_shelf Moving.id_initial_shelf%type DEFAULT NULL,
    p_id_target_shelf Moving.id_target_shelf%type DEFAULT NULL,
    p_date_move Moving.date_move%type DEFAULT NOW(),
    p_type Moving.type%type DEFAULT NULL,
    p_quantity Moving.quantity%type DEFAULT 0
) 
RETURNS VOID AS $$
DECLARE
    v_product_shelf_id INT; -- ID товара на полке, если найден
BEGIN
    -- Добавляем новую запись в таблицу Moving
    INSERT INTO Moving (
        id_product,
        id_initial_place,
        id_target_place,
        id_initial_shelf,
        id_target_shelf,
        date_move,
        type,
        quantity
    ) VALUES (
        p_id_product,
        p_id_initial_place,
        p_id_target_place,
        p_id_initial_shelf,
        p_id_target_shelf,
        p_date_move,
        p_type,
        p_quantity
    );

    -- Логика обновления или добавления записи в Product_on_shelf
    IF p_type = 'приход' THEN
        -- Попытка найти существующую запись в таблице Product_on_shelf
        SELECT id_product_shelf
        INTO v_product_shelf_id
        FROM Product_on_shelf
        WHERE id_product = p_id_product AND id_shelf = p_id_target_shelf;

        IF FOUND THEN
            -- Если запись найдена, увеличиваем количество
            UPDATE Product_on_shelf
            SET quantity = quantity + p_quantity
            WHERE id_product_shelf = v_product_shelf_id;
        ELSE
            -- Если запись не найдена, создаем новую
            INSERT INTO Product_on_shelf (
                id_product,
                id_shelf,
                id_price_list,
                quantity,
                automarkdown_status
            ) VALUES (
                p_id_product,
                p_id_target_shelf,
                NULL, -- Указываем значение прайс-листа или NULL, если неизвестно
                p_quantity,
                'нет'
            );
        END IF;
    ELSIF p_type = 'расход' THEN
        -- Уменьшение количества на исходной полке
        SELECT id_product_shelf
        INTO v_product_shelf_id
        FROM Product_on_shelf
        WHERE id_product = p_id_product AND id_shelf = p_id_initial_shelf;

        IF FOUND THEN
            UPDATE Product_on_shelf
            SET quantity = quantity - p_quantity
            WHERE id_product_shelf = v_product_shelf_id;

            -- Проверяем, не стало ли количество отрицательным
            IF (SELECT quantity FROM Product_on_shelf WHERE id_product_shelf = v_product_shelf_id) < 0 THEN
                RAISE EXCEPTION 'Количество товара на полке не может быть отрицательным';
            END IF;
        ELSE
            RAISE EXCEPTION 'Товар на исходной полке не найден';
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;




-- Процедура Register_inventory
-- Регистрирует инвентаризацию

CREATE OR REPLACE FUNCTION Register_inventory(
    p_id_point              Inventory.id_point%type,
    p_id_employee           Inventory.id_employee%type,
    p_date_create           Write_off.date_create%type DEFAULT NOW(),
    p_id_product            Inventory_result.id_product%type DEFAULT NULL,
    p_actual_quantity       Inventory_result.quantity%type DEFAULT NULL,
    p_quantity              Write_off.quantity%type DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    v_accepted_quantity INT;
    v_sold_quantity INT;
    v_written_off_quantity INT;
    v_on_shelf_quantity INT;
    v_expected_quantity INT;
    v_delta INT;
BEGIN
    -- Вставка новой строки в таблицу Inventory
    INSERT INTO Inventory(id_point, id_employee, date_create)
    VALUES (p_id_point, p_id_employee, p_date_create);

    -- Получаем суммарное количество принятого товара
    SELECT COALESCE(SUM(quantity), 0)
    INTO v_accepted_quantity
    FROM Acceptance_of_goods
    WHERE id_product = p_id_product;

    -- Получаем суммарное количество проданного товара
    SELECT COALESCE(SUM(quantity), 0)
    INTO v_sold_quantity
    FROM Sale
    WHERE id_product = p_id_product;

    -- Получаем суммарное количество списанного товара
    SELECT COALESCE(SUM(quantity), 0)
    INTO v_written_off_quantity
    FROM Write_Off
    WHERE id_product = p_id_product;

    -- Получаем суммарное количество товара на полках
    SELECT COALESCE(SUM(quantity), 0)
    INTO v_on_shelf_quantity
    FROM Product_on_shelf
    WHERE id_product = p_id_product;

    -- Рассчитываем ожидаемое количество товара
    v_expected_quantity := v_accepted_quantity - v_sold_quantity - v_written_off_quantity + v_on_shelf_quantity;

    -- Рассчитываем отклонение (фактическое количество - ожидаемое количество)
    v_delta := p_actual_quantity - v_expected_quantity;

    -- Вставка результата инвентаризации в таблицу Inventory_result
    INSERT INTO Inventory_result(id_inventory, id_product, quantity, delta)
    VALUES (CURRVAL('inventory_id_inventory_seq'), p_id_product, p_actual_quantity, v_delta);

END;
$$ LANGUAGE plpgsql;


-- Функция Register_write_off


CREATE OR REPLACE FUNCTION Register_write_off(
    p_id_product Write_Off.id_product%type,
    p_id_employee Write_Off.id_employee%type,
    p_id_place Write_Off.id_place%type,
    p_id_product_shelf Write_Off.id_product_shelf%type,
    p_quantity Write_Off.quantity%type,
    p_reason Write_Off.reason%type,
    p_comment Write_Off.comment%type DEFAULT NULL,
    p_date_create Write_Off.date_create%type DEFAULT NOW()
) RETURNS VOID AS $$
BEGIN
    -- Проверка наличия товара на полке
    IF NOT EXISTS (
        SELECT 1 
        FROM Product_on_shelf 
        WHERE id_product = p_id_product 
          AND id_shelf = p_id_product_shelf
    ) THEN
        RAISE EXCEPTION 'Товар отсутствует на указанной полке';
    END IF;

    -- Проверка достаточного количества товара
    IF (SELECT quantity 
        FROM Product_on_shelf 
        WHERE id_product = p_id_product 
          AND id_shelf = p_id_product_shelf) < p_quantity THEN
        RAISE EXCEPTION 'Недостаточное количество товара на полке';
    END IF;

    -- Вставка записи о списании
    INSERT INTO Write_Off (
        id_product, id_employee, id_place, id_product_shelf, 
        date_create, quantity, reason, comment
    )
    VALUES (
        p_id_product, p_id_employee, p_id_place, p_id_product_shelf, 
        p_date_create, p_quantity, p_reason, p_comment
    );

    -- Обновление или удаление товара на полке
    UPDATE Product_on_shelf
    SET quantity = quantity - p_quantity
    WHERE id_product = p_id_product 
      AND id_shelf = p_id_product_shelf;

    DELETE FROM Product_on_shelf
    WHERE id_product = p_id_product 
      AND id_shelf = p_id_product_shelf 
      AND quantity = 0;
END;
$$ LANGUAGE plpgsql;

/**

ТРИГГЕРЫ

**/

-- Триггер before_insert_acceptance_goods
-- Срабатывает перед вставкой в таблицу acceptance_of_goods


CREATE OR REPLACE FUNCTION before_insert_acceptance_goods() 
RETURNS TRIGGER AS
$$
BEGIN
    -- Вызываем функцию проверки соответствия товара
    PERFORM check_product_compliance(
        NEW.id_acceptance,  -- id_acceptance
        NEW.quantity,  -- фактическое количество
        NEW.date_create,  -- дата создания приемки товара
        NEW.id_product  -- id_product
    );

    -- Устанавливаем значения для is_match и comment на основании результата функции
    SELECT compliance, comment INTO NEW.is_match, NEW.comment
    FROM check_product_compliance(
        NEW.id_acceptance, NEW.quantity, NEW.date_create, NEW.id_product);

    -- Возвращаем строку для вставки
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Создаем сам триггер
CREATE TRIGGER Before_insert_acceptance_goods
BEFORE INSERT ON acceptance_of_goods
FOR EACH ROW
EXECUTE FUNCTION before_insert_acceptance_goods();



-- Триггер after_insert_update_acceptance_goods
-- Срабатывает после вставки для обновления информации в других таблицах


-- Функция триггера, которая вызывает процедуру send_request_change_status
CREATE OR REPLACE FUNCTION after_insert_update_acceptance_good_trigger()
RETURNS TRIGGER AS
$$
BEGIN
    -- Вызов функции send_request_change_status с параметром id_accept_good
    PERFORM send_request_change_status(NEW.id_accept_good);

    -- Возвращаем строку, вставленную или обновленную
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Триггер для выполнения после вставки или обновления записи в Acceptance_of_goods
CREATE TRIGGER after_insert_update_acceptance_good
AFTER INSERT OR UPDATE ON acceptance_of_goods
FOR EACH ROW
EXECUTE FUNCTION after_insert_update_acceptance_good_trigger();



-- Триггер after_insert_acceptance_goods
-- Срабатывает после вставки для логирования данных

CREATE OR REPLACE FUNCTION after_insert_acceptance_good_trigger()
RETURNS TRIGGER AS $$
DECLARE
    v_id_place INT;
BEGIN
    -- Получаем id_place из таблицы Acceptance
    SELECT id_place
    INTO v_id_place
    FROM Acceptance
    WHERE id_acceptance = NEW.id_acceptance;

    -- Проверяем, было ли найдено значение id_place
    IF v_id_place IS NULL THEN
        RAISE EXCEPTION 'Не удалось найти id_place для id_acceptance: %', NEW.id_acceptance;
    END IF;

    -- Вызываем функцию register_movement_goods
    PERFORM register_movement_goods(
        p_id_product => NEW.id_product,
        p_id_initial_place => NULL,
        p_id_target_place => v_id_place,
        p_id_initial_shelf => NULL,
        p_id_target_shelf => NULL, -- Если данные о целевой полке неизвестны
        p_date_move => NEW.date_create,
        p_type => 'приход',
        p_quantity => NEW.quantity
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER after_insert_acceptance_good
AFTER INSERT ON Acceptance_of_goods
FOR EACH ROW
EXECUTE FUNCTION after_insert_acceptance_good_trigger();
